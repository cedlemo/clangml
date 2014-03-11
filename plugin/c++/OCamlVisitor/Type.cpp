#include "OCamlVisitor.h"


/****************************************************
 * {{{1 Types
 */


bool
OCamlVisitor::TraverseType (clang::QualType T)
{
  TRACE;

  Base::TraverseType (T);
  ptr<Ctyp_> unqual = stack.pop ();

  clang::Qualifiers quals = T.getLocalQualifiers ();

  std::vector<TypeQualifier> qualifiers;
  if (quals.hasConst ())	qualifiers.push_back (TQ_Const);
  if (quals.hasVolatile ())	qualifiers.push_back (TQ_Volatile);
  if (quals.hasRestrict ())	qualifiers.push_back (TQ_Restrict);

  switch (quals.getObjCGCAttr ())
    {
    case clang::Qualifiers::GCNone:
      // Nothing to add.
      break;
    case clang::Qualifiers::Weak:
      qualifiers.push_back (TQ_Weak);
      break;
    case clang::Qualifiers::Strong:
      qualifiers.push_back (TQ_Strong);
      break;
    }

  switch (quals.getObjCLifetime ())
    {
    case clang::Qualifiers::OCL_None:
      // Nothing to add.
      break;
    case clang::Qualifiers::OCL_ExplicitNone:
      qualifiers.push_back (TQ_OCL_ExplicitNone);
      break;
    case clang::Qualifiers::OCL_Strong:
      qualifiers.push_back (TQ_OCL_Strong);
      break;
    case clang::Qualifiers::OCL_Weak:
      qualifiers.push_back (TQ_OCL_Weak);
      break;
    case clang::Qualifiers::OCL_Autoreleasing:
      qualifiers.push_back (TQ_OCL_Autoreleasing);
      break;
    }

  option<int> addressSpace;
  if (quals.hasAddressSpace ())
    addressSpace = quals.getAddressSpace ();

  ptr<Ctyp> ctyp = mkCtyp ();
  ctyp->t = unqual;
  ctyp->t_cref = ref (T);
  ctyp->t_qual = qualifiers;
  ctyp->t_aspace = addressSpace;
  stack.push (ctyp);

  return true;
}


bool
OCamlVisitor::TraverseBuiltinType (clang::BuiltinType *T)
{
  TRACE;

  BuiltinType bt = translate_builtin_type (T->getKind ());

  stack.push (mkBuiltinType (bt));

  return true;
}



bool
OCamlVisitor::TraversePointerType (clang::PointerType *T)
{
  TRACE;

  ptr<Ctyp> pointee = must_traverse (T->getPointeeType ());

  stack.push (mkPointerType (pointee));

  return true;
}


bool
OCamlVisitor::TraverseFunctionProtoType (clang::FunctionProtoType *T)
{
  TRACE;

  ptr<Ctyp> result = must_traverse (T->getResultType ());
  list<Ctyp> args = traverse_list (arg_type_range (T));

  // TODO: exceptions

  stack.push (mkFunctionProtoType (result, args));

  return true;
}


bool
OCamlVisitor::TraverseFunctionNoProtoType (clang::FunctionNoProtoType *T)
{
  TRACE;

  ptr<Ctyp> result = must_traverse (T->getResultType ());

  stack.push (mkFunctionNoProtoType (result));

  return true;
}




#define UNIMP_TYPE(CLASS)					\
bool								\
OCamlVisitor::Traverse##CLASS##Type (clang::CLASS##Type *type)	\
{								\
  TODO;								\
  Base::Traverse##CLASS##Type (type);				\
  return true;							\
}

UNIMP_TYPE(Atomic)
UNIMP_TYPE(Attributed)
UNIMP_TYPE(Auto)
UNIMP_TYPE(BlockPointer)
UNIMP_TYPE(Complex)
bool
OCamlVisitor::TraverseConstantArrayType (clang::ConstantArrayType *T)
{
  TRACE;

  ptr<Ctyp> element = must_traverse (T->getElementType ());
  uint64_t size = T->getSize ().getZExtValue ();

  stack.push (mkConstantArrayType (element, size));

  return true;
}


UNIMP_TYPE(Decltype)
UNIMP_TYPE(DependentName)
UNIMP_TYPE(DependentSizedArray)
UNIMP_TYPE(DependentSizedExtVector)
UNIMP_TYPE(DependentTemplateSpecialization)
bool
OCamlVisitor::TraverseElaboratedType (clang::ElaboratedType *T)
{
  TRACE;

  TraverseNestedNameSpecifier (T->getQualifier ());
  ptr<Ctyp> type = must_traverse (T->getNamedType ());

  stack.push (mkElaboratedType (type));

  return true;
}


bool
OCamlVisitor::TraverseEnumType (clang::EnumType *T)
{
  TRACE;

  clang::StringRef name = T->getDecl ()->getName ();

  stack.push (mkEnumType (name));

  return true;
}


UNIMP_TYPE(ExtVector)
bool
OCamlVisitor::TraverseIncompleteArrayType (clang::IncompleteArrayType *T)
{
  TRACE;

  ptr<Ctyp> element = must_traverse (T->getElementType ());

  stack.push (mkIncompleteArrayType (element));

  return true;
}


UNIMP_TYPE(InjectedClassName)
UNIMP_TYPE(LValueReference)
UNIMP_TYPE(MemberPointer)
UNIMP_TYPE(ObjCInterface)
UNIMP_TYPE(ObjCObjectPointer)
UNIMP_TYPE(ObjCObject)
UNIMP_TYPE(PackExpansion)
bool
OCamlVisitor::TraverseParenType (clang::ParenType *T)
{
  TRACE;

  ptr<Ctyp> inner = must_traverse (T->getInnerType ());

  stack.push (mkParenType (inner));

  return true;
}


bool
OCamlVisitor::TraverseRecordType (clang::RecordType *T)
{
  TRACE;

  TagTypeKind kind = translate_tag_type_kind (T->getDecl ()->getTagKind ());
  clang::StringRef name = T->getDecl ()->getName ();

  stack.push (mkRecordType (kind, name));

  return true;
}


UNIMP_TYPE(RValueReference)
UNIMP_TYPE(SubstTemplateTypeParmPack)
UNIMP_TYPE(SubstTemplateTypeParm)
UNIMP_TYPE(TemplateSpecialization)
UNIMP_TYPE(TemplateTypeParm)
bool
OCamlVisitor::TraverseTypedefType (clang::TypedefType *T)
{
  TRACE;

  clang::StringRef name = T->getDecl ()->getName ();

  stack.push (mkTypedefType (name));

  return true;
}


bool
OCamlVisitor::TraverseTypeOfExprType (clang::TypeOfExprType *T)
{
  TRACE;

  ptr<Expr> expr = must_traverse (T->getUnderlyingExpr ());

  stack.push (mkTypeOfExprType (expr));

  return true;
}


bool
OCamlVisitor::TraverseTypeOfType (clang::TypeOfType *T)
{
  TRACE;

  ptr<Ctyp> type = must_traverse (T->getUnderlyingType ());

  stack.push (mkTypeOfType (type));

  return true;
}


UNIMP_TYPE(UnaryTransform)
UNIMP_TYPE(UnresolvedUsing)
bool
OCamlVisitor::TraverseVariableArrayType (clang::VariableArrayType *T)
{
  TRACE;

  ptr<Ctyp> element = must_traverse (T->getElementType ());
  ptr<Expr> size = must_traverse (T->getSizeExpr ());

  stack.push (mkVariableArrayType (element, size));

  return true;
}


UNIMP_TYPE(Vector)


// }}}