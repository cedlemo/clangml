open Clang
open Prelude


type state = {
  inserted_decls : Ast.stmt list;
  inserted_stmts : Ast.stmt list;
  generated_vars : int;
}

let empty_state = {
  inserted_decls = [];
  inserted_stmts = [];
  generated_vars = 0;
}


let clear_state state = {
  state with
  inserted_decls = [];
  inserted_stmts = [];
}


let make_temporary state =
  let var = "tmp" ^ string_of_int state.generated_vars in
  ({ state with generated_vars = state.generated_vars + 1 }, var)


let assign var expr =
  let open Ast in

  ExprStmt {
    e = BinaryOperator (
        BO_Assign,
        { e = DeclRefExpr var;
          e_sloc = expr.e_sloc;
          e_type = expr.e_type;
          e_cref = Ref.null;
        },
        expr
      );
    e_sloc = expr.e_sloc;
    e_type = expr.e_type;
    e_cref = Ref.null;
  }


let transform_decl =
  let open Ast in

  let rec v = MapVisitor.({
    map_desg = (fun state desg -> visit_desg v state desg);
    map_decl = (fun state desg -> visit_decl v state desg);
    map_expr;
    map_ctyp = (fun state desg -> visit_ctyp v state desg);
    map_tloc = (fun state desg -> visit_tloc v state desg);
    map_stmt;
  })


  and map_expr state expr =
    match expr.e with
    | ConditionalOperator (cond, then_expr, else_expr) ->
        let (state, var) = make_temporary state in

        let if_stmt = {
          s = IfStmt (
              cond,
              { s = assign var then_expr;
                s_sloc = then_expr.e_sloc;
                s_cref = Ref.null;
              },
              Some { s = assign var else_expr;
                     s_sloc = else_expr.e_sloc;
                     s_cref = Ref.null;
                   }
            );
          s_sloc = cond.e_sloc;
          s_cref = Ref.null;
        } in

        let var_decl = {
          s = DeclStmt [{
              d = VarDecl (
                  Types.tloc_of_ctyp expr.e_sloc expr.e_type,
                  var,
                  None
                );
              d_sloc = cond.e_sloc;
              d_cref = Ref.null;
            }];
          s_sloc = cond.e_sloc;
          s_cref = Ref.null;
        } in

        let (state, if_stmt) = map_stmt state if_stmt in

        let inserted_stmts = if_stmt :: state.inserted_stmts in
        let inserted_decls = var_decl :: state.inserted_decls in

        let e = DeclRefExpr var in

        ({ state with inserted_stmts; inserted_decls }, { expr with e })

    | _ ->
        MapVisitor.visit_expr v state expr


  and map_stmt state stmt =
    match stmt.s with
    | CompoundStmt stmts ->
        let _, stmts =
          List.fold_left (fun (state, stmts) stmt ->
            let (state, stmt) = map_stmt state stmt in
            (
              clear_state state,
              stmt :: state.inserted_stmts @ state.inserted_decls @ stmts
            )
          ) (state, []) stmts
        in

        (state, { stmt with s = CompoundStmt (List.rev stmts) })

    | IfStmt (cond, then_stmt, else_stmt) ->
        let (state, cond) = map_expr state cond in
        let then_stmt = map_sub_stmt state then_stmt in
        let else_stmt = Option.map (map_sub_stmt state) else_stmt in

        (state, { stmt with s = IfStmt (cond, then_stmt, else_stmt) })

    | WhileStmt (cond, body) ->
        let (state, cond) = map_expr state cond in
        let body = map_sub_stmt state body in

        (* Execute the replacement code for the condition again
           after each iteration. *)
        let body = append_stmts body state.inserted_stmts in

        (state, { stmt with s = WhileStmt (cond, body) })

    | _ ->
        MapVisitor.visit_stmt v state stmt


  and map_sub_stmt state stmt =
    let (state, stmt) =
      map_stmt (clear_state state) stmt
    in
    match state.inserted_stmts, state.inserted_decls with
    | [], [] -> stmt
    | stmts, decls ->
        { s = CompoundStmt (List.rev @@ stmt :: stmts @ decls);
          s_sloc = stmt.s_sloc;
          s_cref = Ref.null;
        }


  and append_stmts stmt stmts =
    match stmts with
    | [] -> stmt
    | stmts ->
        { s = CompoundStmt (stmt :: stmts);
          s_sloc = stmt.s_sloc;
          s_cref = Ref.null;
        }


  in

  snd % MapVisitor.visit_decl v empty_state