module Log = Logger.Make(struct let tag = "main" end)

let (%) f g x = f (g x)


type context = {
  (* These are actually lookup sets, but since the number of
     types is typically very small, we use simple lists. *)
  enum_types  : string list;
  class_types : string list;
}


(**
  Turn an underscore_name into a CamelcaseName.
  This function is non-destructive (returns a new string).
 *)
let cpp_name name =
  let rec to_camelcase length name =
    try
      (* If the name starts with an underscore,
         keep that first underscore. *)
      let underscore = String.index_from name 1 '_' in
      String.blit
        name (underscore + 1)
        name underscore
        (length - underscore - 1);
      name.[underscore] <- Char.uppercase name.[underscore];
      to_camelcase (length - 1) name
    with Not_found ->
      (* Second copy here. *)
      String.sub name 0 length
  in
  (* First copy here. *)
  to_camelcase (String.length name) (String.capitalize name)


(*****************************************************
 * Enum (all tycons are nullary)
 *****************************************************)

let enum_intf_for_constant_sum_type (sum_type_name, branches) =
  (* Explicitly make the first enum have value 0, the second have value 2, etc.*)
  let enum_elements =
    List.mapi (fun i (branch_name, _) ->
      (branch_name, Some i)
    ) branches
  in

  Codegen.({
    enum_name = cpp_name sum_type_name;
    enum_elements = enum_elements;
  })


let sum_type_is_enum (sum_type_name, branches) =
  List.for_all (fun (branch_name, types) ->
    types = []
  ) branches


let type_is_enum = let open Parse in function
  | SumType ty -> sum_type_is_enum ty
  | RecordType _ -> false
  | RecursiveType _ -> failwith "type_is_enum cannot handle recursive types"
  | Version _ -> failwith "Version in type list"


(*****************************************************
 * Class (some of the tycons have arguments)
 *****************************************************)


let first_is_clang_pointer = function
  | Parse.ClangType _ :: _ -> true
  | _ -> false


let is_basic_type = function
  | "bool"
  | "char"
  | "int"
  | "float"
  | "string" ->
      true
  | _ ->
      false


let is_nonnull_ptr ctx = function
  | Parse.NamedType name ->
      (* Basic types and enum types are no pointers. *)
      if is_basic_type name || List.mem name ctx.enum_types then
        false
      else
        true
  | _ ->
      (* Clang and option types are nullable and list types are no pointers. *)
      false


let rec translate_type ctx = let open Parse in let open Codegen in function
  | NamedType "bool" ->
      TyBool
  | NamedType "char" ->
      TyChar
  | NamedType "int" ->
      TyInt
  | NamedType "float" ->
      TyFloat
  | NamedType "string" ->
      TyString
  | NamedType name ->
      let ty = TyName (cpp_name name) in
      (* Make sure enum/constant ADTs are passed and stored
         by value, not by pointer. *)
      if List.mem name ctx.enum_types then
        ty
      else if List.mem name ctx.class_types then
        (* Automatic memory management in C++ bridge. *)
        TyTemplate ("ptr", ty)
      else (
        Log.warn "Name '%s' is not an ADT in the same file"
          name;
        (* Plain pointers to anything unknown. *)
        TyPointer (ty)
      )
  | ClangType name ->
      (* Plain pointers to Clang AST nodes. *)
      TyPointer (TyName ("clang::" ^ name))
  | ListOfType ty ->
      TyTemplate ("std::vector", translate_type ctx ty)
  | OptionType (NamedType name as ty) ->
      let ty =
        if is_basic_type name then
          translate_type ctx ty
        else
          TyName (cpp_name name)
      in
      TyTemplate ("option", ty)
  | OptionType ty ->
      TyTemplate ("option", translate_type ctx ty)


(* Constructor arguments. *)
let constructor_params ctx types =
  let open Codegen in
  List.mapi (fun i ty ->
    { empty_decl with
      decl_type = translate_type ctx ty;
      decl_name = "arg" ^ string_of_int i;
    }
  ) types


let int_const_fn ty name value =
  let open Codegen in
  MemberFunction {
    flags  = [Virtual];
    retty  = TyName ty;
    name   = name;
    params = [];
    this_flags = [Const];
    body   = CompoundStmt [
      Return (IntLit value)
    ];
  }

let tag_const  = int_const_fn "tag_t"    "tag"
let size_const = int_const_fn "mlsize_t" "size"


let toValue fields =
  let open Codegen in

  let body =
    CompoundStmt [
      Return (
        FCall (
          "value_of_adt",
          IdExpr "ctx"
          :: IdExpr "this"
          :: fields
        )
      );
    ]
  in
  MemberFunction {
    flags  = [Virtual];
    retty  = TyName "value";
    name   = "ToValue";
    params = [{
      empty_decl with
      decl_type = TyReference (TyName "value_of_context");
      decl_name = "ctx";
    }];
    this_flags = [Const];
    body;
  }


let class_intf_for_sum_type ctx (sum_type_name, branches) =
  let open Codegen in

  (* Base class *)
  let base = {
    class_name = cpp_name sum_type_name;
    class_bases = ["OCamlADTBase"];
    class_fields = [];
    class_methods = [];
  } in

  let derived =
    let explicit = [Explicit] in

    let make_derived tag (branch_name, types) =
      let toValue =
        toValue (List.mapi (fun i ty -> IdExpr ("field" ^ string_of_int i)) types)
      in

      (* Create 1 or 2 constructors, one with clang pointer (if requested),
         the other without, and defaulting it to NULL. *)
      let constructors =
        (* Constructor initialiser list. *)
        let init =
          List.mapi (fun i ty ->
            ("field" ^ string_of_int i, "arg" ^ string_of_int i)
          ) types
        in

        let assert_fn i =
          Expression (FCall ("assert", [IdExpr ("arg" ^ string_of_int i)]))
        in

        let body =
          (* Enforce invariants. *)
          CompoundStmt (List.mapi (fun i ty ->
            if is_nonnull_ptr ctx ty then
              [assert_fn i]
            else
              []
          ) types |> List.flatten)
        in

        let constructor params init =
          let flags =
            (* Explicit constructor only if it's a unary constructor. *)
            if List.length params = 1 then
              explicit
            else
              []
          in
          MemberConstructor (flags, params, init, body)
        in

        let params = constructor_params ctx types in

        (* Constructor with pointer to clang object. *)
        let ctors = [constructor params init] in
        if first_is_clang_pointer types then
          (* Constructor without clang object; pointer will be NULL. *)
          constructor (List.tl params) (("field0", "NULL") :: List.tl init)
          :: ctors
        else
          ctors
      in

      let fields =
        List.mapi (fun i ty ->
          MemberField {
            empty_decl with
            decl_type = translate_type ctx ty;
            decl_name = "field" ^ string_of_int i;
          }
        ) types
      in

      {
        class_name = branch_name ^ base.class_name;
        class_bases = [base.class_name];
        class_fields = fields;
        class_methods = size_const (List.length types) :: tag_const tag :: toValue :: constructors;
      }
    in

    let (nullary, parameterised) =
      List.partition
        (fun branch -> snd branch = [])
        branches
    in
    (* First, nullary constructors. *)
    List.mapi make_derived nullary
    @ (* Then, tycons with arguments. *)
    List.mapi make_derived parameterised
  in
  base :: derived


(*****************************************************
 * Main
 *****************************************************)

let gen_code_for_sum_type ctx (sum_type : Parse.sum_type) =
  if List.mem (fst sum_type) ctx.enum_types then
    [Codegen.Enum (enum_intf_for_constant_sum_type sum_type)]
  else
    let (sum_type_name, branches) = sum_type in

    List.map (fun i -> Codegen.Class i)
      (class_intf_for_sum_type ctx sum_type)

    @ List.map (fun (branch_name, types) ->
        let open Codegen in
        let ty =
          TyName (cpp_name branch_name ^
                  cpp_name sum_type_name)
        in
        let args =
          List.mapi (fun i ty ->
            IdExpr ("arg" ^ string_of_int i)
          ) types
        in
        Function {
          flags  = [Static; Inline];
          retty  = TyTemplate ("ptr", ty);
          name   = "mk" ^ cpp_name branch_name;
          params = constructor_params ctx types;
          this_flags = [];
          body   = CompoundStmt [
            Return (
              New (ty, args)
            )
          ];
        }
      ) branches


let class_intf_for_record_type ctx (record_name, fields) =
  let open Codegen in

  let class_fields =
    List.map (fun (name, ty) ->
      MemberField {
        empty_decl with
        decl_type = translate_type ctx ty;
        decl_name = name;
      }
    ) fields
  in

  let toValue =
    toValue (List.map (fun (name, ty) -> IdExpr (name)) fields)
  in

  {
    class_name = cpp_name record_name;
    class_bases = ["OCamlADTBase"];
    class_fields;
    class_methods = [size_const (List.length fields); tag_const 0; toValue];
  }


let gen_code_for_record_type ctx (record_type : Parse.record_type) =
  let open Codegen in

  let factory =
    let class_name = cpp_name (fst record_type) in
    let ty = TyName class_name in
    Function {
      flags  = [Static; Inline];
      retty  = TyTemplate ("ptr", ty);
      name   = "mk" ^ class_name;
      params = [];
      this_flags = [];
      body   = CompoundStmt [
        Return (
          New (ty, [])
        )
      ];
    }
  in

  [Codegen.Class (class_intf_for_record_type ctx record_type); factory]


let name_of_type = let open Parse in function
  | SumType (name, _)
  | RecordType (name, _) -> name
  | Version _ -> failwith "version has no name"
  | RecursiveType _ -> failwith "recursive types have no name"


let gen_code_for_ocaml_type ctx = let open Parse in function
  | SumType ty -> gen_code_for_sum_type ctx ty
  | RecordType ty -> gen_code_for_record_type ctx ty
  | Version _ -> Log.err "version in recursive type"
  | RecursiveType _ -> Log.err "recursive type in recursive type"


let gen_code_for_rec_type ctx = function
  | Parse.RecursiveType rec_types ->
      (* Generate forward declarations for recursive types.
         Only consider types that will be turned into classes,
         as recursive type definitions may contain some enum
         types, as well (even though that would be useless). *)
      List.map (fun sum_type ->
        Codegen.Forward (cpp_name @@ name_of_type sum_type)
      ) (List.filter (not % type_is_enum) rec_types)
      @
      (
        List.map (gen_code_for_ocaml_type ctx) rec_types
        |> List.flatten
      )
  | Parse.Version version ->
      let open Codegen in
      let ty = TyConst (TyPointer (TyConst TyChar)) in
      [Variable (ty, "version", StrLit version)]
  | ty ->
      gen_code_for_ocaml_type ctx ty


(* Partition by enum/class types. *)
let partition_type_names =
  List.fold_left (fun (enums, classes) -> function
    | Parse.SumType ty ->
        if sum_type_is_enum ty then
          (fst ty :: enums, classes)
        else
          (enums, fst ty :: classes)
    | Parse.RecordType (name, _) ->
        (enums, name :: classes)
    | Parse.Version _ -> Log.err "version does not have a type name"
    | Parse.RecursiveType _ -> Log.err "recursive types do not have a type name"
  ) ([], [])

let flatten_recursive_types =
  List.flatten % List.map (function
    | Parse.RecursiveType tys -> tys
    | Parse.Version _ -> []
    | ty -> [ty]
  )


let code_gen basename (ocaml_types : Parse.ocaml_type list) =
  let (enum_types, class_types) =
    (* Get all types, including the ones in a recursive definition,
       as a flat list. *)
    flatten_recursive_types ocaml_types
    |> partition_type_names
  in

  (* Extract type names. *)
  let ctx = { enum_types; class_types; } in

  (* Get AST version. *)
  begin
    match
      List.map (function
        | Parse.Version version -> [version]
        | _ -> []
      ) ocaml_types
      |> List.flatten
    with
    | [version] -> ()
    | [] ->
        Log.err "No version found"
    | versions ->
        Log.err "Multiple versions found: [%a]"
          (Formatx.pp_list Formatx.pp_print_string) versions
  end;

  let cpp_types =
    List.map (gen_code_for_rec_type ctx) ocaml_types
    |> List.flatten
  in
  begin (* interface *)
    let fh = open_out (basename ^ ".h") in
    let cg = Codegen.make_codegen_with_channel fh in
    Codegen.emit_intfs basename cg cpp_types;
    Codegen.flush cg;
    close_out fh;
  end;
  begin (* implementation *)
    let fh = open_out (basename ^ ".cpp") in
    let cg = Codegen.make_codegen_with_channel fh in
    Codegen.emit_impls basename cg cpp_types;
    Codegen.flush cg;
    close_out fh;
  end;
;;


let parse_and_generate basename source =
  let ocaml_types = Parse.parse_file source in
  (*print_endline (Show.show_list<Parse.ocaml_type> ocaml_types);*)
  code_gen basename ocaml_types

  (* TODO: Think about detecting versioning mismatch between generated and ocaml ast.*)
  (* Maybe keep a version number around someplace?*)


let () =
  match Sys.argv with
  | [|_; basename; source|] ->
      parse_and_generate basename source
  | _ ->
      print_endline "Usage: c++adt <basename> <source>"
