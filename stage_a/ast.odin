package main

// AST for Qoz-v2. Each node kind is a distinct struct. Where v1 stored
// everything as a single Node with a payload union, Stage A uses concrete
// pointer types per kind. This shape maps cleanly to Qoz-v2 ADTs when
// Stage B rewrites the compiler in Qoz-v2.

Span :: struct {
    file:   string,
    line:   int,
    column: int,
}

// --- Expressions ---

Expr :: union {
    ^Expr_Int_Lit,
    ^Expr_Float_Lit,
    ^Expr_String_Lit,
    ^Expr_Char_Lit,
    ^Expr_Bool_Lit,
    ^Expr_Nil_Lit,
    ^Expr_Ident,
    ^Expr_Path,
    ^Expr_Unary,
    ^Expr_Binary,
    ^Expr_Assign,
    ^Expr_Call,
    ^Expr_Field,
    ^Expr_Index,
    ^Expr_Cast,
    ^Expr_New,
    ^Expr_Try,
    ^Expr_Tuple,
    ^Expr_Record,
    ^Expr_Closure,
    ^Expr_Block,
    ^Expr_If,
    ^Expr_Match,
    ^Expr_While,
    ^Expr_For,
    ^Expr_Return,
    ^Expr_Defer,
    ^Expr_Size_Of,
    ^Expr_Array_Lit,
}

Expr_Size_Of :: struct {
    span:   Span,
    target: ^Type_Expr,
}

Expr_Array_Lit :: struct {
    span:  Span,
    elems: []Expr,
}

Expr_Int_Lit    :: struct { span: Span, text: string }
Expr_Float_Lit  :: struct { span: Span, text: string }
Expr_String_Lit :: struct { span: Span, text: string }       // includes the quotes; unescape in semantic
Expr_Char_Lit   :: struct { span: Span, text: string }
Expr_Bool_Lit   :: struct { span: Span, value: bool }
Expr_Nil_Lit    :: struct { span: Span }

Expr_Ident      :: struct { span: Span, name: string }

// foo.bar.baz or Shape.Circle. A non-empty list of identifier segments
// joined by '.'. Disambiguation between module access, field access, and
// variant constructor happens at semantic analysis, not at parse time.
Expr_Path :: struct {
    span: Span,
    segs: []string,
}

Unary_Op :: enum { Neg, Not, Deref, Addr }
Expr_Unary :: struct { span: Span, op: Unary_Op, rhs: Expr }

Binary_Op :: enum {
    Add, Sub, Mul, Div, Mod,
    Eq, Ne, Lt, Gt, Le, Ge,
    And, Or,
    Range, Range_Inclusive,
}
Expr_Binary :: struct { span: Span, op: Binary_Op, lhs, rhs: Expr }

Assign_Op :: enum { Set, Add_Set, Sub_Set, Mul_Set, Div_Set, Mod_Set }
Expr_Assign :: struct { span: Span, op: Assign_Op, target, value: Expr }

Expr_Call  :: struct { span: Span, callee: Expr, args: []Expr }
Expr_Field :: struct { span: Span, base: Expr, name: string }
Expr_Index :: struct { span: Span, base: Expr, index: Expr }
Expr_Cast  :: struct { span: Span, value: Expr, target: ^Type_Expr }
Expr_New   :: struct { span: Span, value: Expr }                 // new <expr>
Expr_Try   :: struct { span: Span, value: Expr }                 // <expr>?

Expr_Tuple :: struct { span: Span, elems: []Expr }

Record_Field :: struct { name: string, value: Expr }
Expr_Record :: struct {
    span:    Span,
    type:    ^Type_Expr,             // may be nil (inferred from context)
    fields:  []Record_Field,
    base:    Expr,                   // ..base for partial update; nil if none
}

Closure_Param :: struct { name: string, type: ^Type_Expr }       // type may be nil
Expr_Closure :: struct {
    span:   Span,
    params: []Closure_Param,
    ret:    ^Type_Expr,
    body:   Expr,
}

Expr_Block :: struct {
    span: Span,
    stmts: []Stmt,
    tail:  Expr,                                                  // optional trailing expression
}

Expr_If :: struct {
    span: Span,
    cond: Expr,
    then_b: ^Expr_Block,
    else_b: Expr,                                                 // either nil, ^Expr_Block, or ^Expr_If
}

Match_Arm :: struct {
    pat:    Pattern,
    guard:  Expr,                                                 // nil if no guard
    body:   Expr,
}
Expr_Match :: struct {
    span:    Span,
    scrutinee: Expr,
    arms:    []Match_Arm,
}

Expr_While :: struct { span: Span, cond: Expr, body: ^Expr_Block }
Expr_For :: struct {
    span:    Span,
    binding: string,
    iter:    Expr,
    body:    ^Expr_Block,
}
Expr_Return :: struct { span: Span, value: Expr }                 // value may be nil
Expr_Defer  :: struct { span: Span, body: Expr }

// --- Patterns ---

Pattern :: union {
    ^Pat_Wild,
    ^Pat_Bind,
    ^Pat_Lit_Int,
    ^Pat_Lit_String,
    ^Pat_Lit_Bool,
    ^Pat_Variant,
    ^Pat_Tuple,
    ^Pat_Record,
}

Pat_Wild       :: struct { span: Span }
Pat_Bind       :: struct { span: Span, name: string }
Pat_Lit_Int    :: struct { span: Span, text: string }
Pat_Lit_String :: struct { span: Span, text: string }
Pat_Lit_Bool   :: struct { span: Span, value: bool }

Pat_Variant :: struct {
    span:  Span,
    path:  ^Expr_Path,                                            // T.Variant
    pos:   []Pattern,                                             // positional payloads
    named: []Pat_Named_Field,                                     // named-field payloads
}
Pat_Named_Field :: struct { name: string, pat: Pattern }

Pat_Tuple  :: struct { span: Span, elems: []Pattern }
Pat_Record :: struct {
    span:    Span,
    fields:  []Pat_Named_Field,
    has_rest: bool,                                               // .. for "and the rest"
}

// --- Type expressions ---

Type_Expr :: union {
    ^Type_Named,
    ^Type_Ptr,
    ^Type_Fn,
    ^Type_Tuple,
    ^Type_Unit,
}

// Named type, possibly with generic arguments. Foo, Vec<i32>, Result<T, E>.
Type_Named :: struct {
    span: Span,
    path: []string,                                               // module path: ["std", "collections", "Vec"]
    args: []^Type_Expr,
}

Type_Ptr   :: struct { span: Span, inner: ^Type_Expr }            // *T
Type_Fn    :: struct { span: Span, params: []^Type_Expr, ret: ^Type_Expr }
Type_Tuple :: struct { span: Span, elems: []^Type_Expr }
Type_Unit  :: struct { span: Span }

// --- Statements ---

Stmt :: union {
    ^Stmt_Let,
    ^Stmt_Var,
    ^Stmt_Let_Else,
    ^Stmt_Expr,
}

// `let pat = expr else { diverging_block }`
// The else block runs when `pat` does not match `expr`. Its bindings from the
// pattern come into scope after this statement.
Stmt_Let_Else :: struct {
    span:        Span,
    pat:         Pattern,
    value:       Expr,
    else_block:  ^Expr_Block,
}

Stmt_Let :: struct {
    span: Span,
    name: string,
    type: ^Type_Expr,                                             // nil if inferred
    value: Expr,
}
Stmt_Var :: struct {
    span: Span,
    name: string,
    type: ^Type_Expr,
    value: Expr,
}
Stmt_Expr :: struct { span: Span, expr: Expr }                    // expression statement; value discarded

// --- Top-level declarations ---

Decl :: union {
    ^Decl_Import,
    ^Decl_Fn,
    ^Decl_Struct,
    ^Decl_Enum,
    ^Decl_Type_Alias,
    ^Decl_Const,
    ^Decl_External,
    ^Decl_Link,
}

Decl_Type_Alias :: struct {
    span:        Span,
    name:        string,
    type_params: []string,
    target:      ^Type_Expr,
}

Decl_Import :: struct {
    span: Span,
    path: []string,                                               // "std/fmt" -> ["std", "fmt"]
    alias: string,                                                // "" if no alias
}

Fn_Param :: struct { name: string, type: ^Type_Expr }
Decl_Fn :: struct {
    span:       Span,
    name:       string,
    type_params: []string,                                        // <T, U>
    params:     []Fn_Param,
    ret:        ^Type_Expr,                                       // nil means unit
    body:       ^Expr_Block,
    operator:   string,                                           // if set, registers fn as `[]`, `+`, etc. for its first-param's type
}

Struct_Field :: struct { name: string, type: ^Type_Expr }
Decl_Struct :: struct {
    span:       Span,
    name:       string,
    type_params: []string,
    fields:     []Struct_Field,
}

Variant_Payload_Kind :: enum { None, Positional, Named }
Variant_Decl :: struct {
    span: Span,
    name: string,
    kind: Variant_Payload_Kind,
    pos:  []^Type_Expr,
    named: []Struct_Field,
}
Decl_Enum :: struct {
    span:        Span,
    name:        string,
    type_params: []string,
    variants:    []Variant_Decl,
}

Decl_Const :: struct {
    span: Span,
    name: string,
    type: ^Type_Expr,
    value: Expr,
}

Decl_External :: struct {
    span:    Span,
    name:    string,                                              // qoz-side name
    symbol:  string,                                              // C symbol after external("...")
    params:  []Fn_Param,
    ret:     ^Type_Expr,
}

Decl_Link :: struct {
    span: Span,
    kind: Link_Kind,
    name: string,
}
Link_Kind :: enum { Library, Framework }

// --- Attributes ---

Attribute :: struct {
    span:       Span,
    name:       string,
    string_arg: string,
    has_arg:    bool,
}

// --- File ---

File :: struct {
    path:     string,
    decls:    []Decl,
    packages: []string,                                           // package names known across loaded files
}
