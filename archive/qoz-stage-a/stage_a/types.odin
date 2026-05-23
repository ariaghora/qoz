package main

import "core:fmt"
import "core:strings"

// Normalised type representation used by the type checker.
// Distinct from the parser-surface ^Type_Expr, which carries spans and
// references to user-written type identifiers. A Ty is the resolved form:
// every named type has been looked up against the file's declarations,
// every primitive has its width and signedness recorded, and there are no
// dangling references.

Ty :: union {
    ^Ty_Int,
    ^Ty_Float,
    ^Ty_Bool,
    ^Ty_Char,
    ^Ty_String,
    ^Ty_Cstring,
    ^Ty_Unit,
    ^Ty_Nil,
    ^Ty_Ptr,
    ^Ty_Tuple,
    ^Ty_Fn,
    ^Ty_Adt,
    ^Ty_Record,
    ^Ty_Var,
    ^Ty_Error,
}

// A type variable. Used inside generic procedures and types. The id is unique
// across the program. The name is the source-level identifier (e.g. "T") and
// is kept for error messages.
Ty_Var :: struct {
    id:   int,
    name: string,
}

Ty_Int :: struct {
    width:   int,        // 8, 16, 32, 64. Zero means untyped.
    signed:  bool,
    untyped: bool,
}
Ty_Float :: struct {
    width:   int,        // 32 or 64. Zero means untyped.
    untyped: bool,
}
Ty_Bool   :: struct {}
Ty_Char   :: struct {}
Ty_String  :: struct {}
Ty_Cstring :: struct {}
Ty_Unit    :: struct {}
Ty_Nil    :: struct {}
Ty_Ptr    :: struct { inner: Ty }
Ty_Tuple  :: struct { elems: []Ty }
Ty_Fn     :: struct { params: []Ty, ret: Ty }
Ty_Adt    :: struct { name: string, args: []Ty }
Ty_Record :: struct { name: string, args: []Ty }
Ty_Error  :: struct {}

// --- Constructors ---

ty_int :: proc(width: int, signed: bool, allocator := context.allocator) -> Ty {
    t := new(Ty_Int, allocator); t.width = width; t.signed = signed; t.untyped = false
    return t
}
ty_untyped_int :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Int, allocator); t.width = 0; t.signed = true; t.untyped = true
    return t
}
ty_float :: proc(width: int, allocator := context.allocator) -> Ty {
    t := new(Ty_Float, allocator); t.width = width; t.untyped = false
    return t
}
ty_untyped_float :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Float, allocator); t.width = 0; t.untyped = true
    return t
}
ty_bool :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Bool, allocator); return t
}
ty_char :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Char, allocator); return t
}
ty_string :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_String, allocator); return t
}
ty_cstring :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Cstring, allocator); return t
}
ty_unit :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Unit, allocator); return t
}
ty_nil :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Nil, allocator); return t
}
ty_error :: proc(allocator := context.allocator) -> Ty {
    t := new(Ty_Error, allocator); return t
}
ty_ptr :: proc(inner: Ty, allocator := context.allocator) -> Ty {
    t := new(Ty_Ptr, allocator); t.inner = inner; return t
}
ty_fn :: proc(params: []Ty, ret: Ty, allocator := context.allocator) -> Ty {
    t := new(Ty_Fn, allocator); t.params = params; t.ret = ret; return t
}
ty_adt :: proc(name: string, args: []Ty, allocator := context.allocator) -> Ty {
    t := new(Ty_Adt, allocator); t.name = name; t.args = args; return t
}
ty_record :: proc(name: string, args: []Ty, allocator := context.allocator) -> Ty {
    t := new(Ty_Record, allocator); t.name = name; t.args = args; return t
}
ty_tuple :: proc(elems: []Ty, allocator := context.allocator) -> Ty {
    t := new(Ty_Tuple, allocator); t.elems = elems; return t
}
ty_var :: proc(id: int, name: string, allocator := context.allocator) -> Ty {
    t := new(Ty_Var, allocator); t.id = id; t.name = name; return t
}

// --- Spelling for error messages ---

ty_to_string :: proc(t: Ty) -> string {
    switch v in t {
    case ^Ty_Int:
        if v.untyped do return "<untyped int>"
        if v.signed do return fmt.tprintf("i%d", v.width)
        return fmt.tprintf("u%d", v.width)
    case ^Ty_Float:
        if v.untyped do return "<untyped float>"
        return fmt.tprintf("f%d", v.width)
    case ^Ty_Bool:   return "bool"
    case ^Ty_Char:   return "char"
    case ^Ty_String:  return "string"
    case ^Ty_Cstring: return "cstring"
    case ^Ty_Unit:    return "unit"
    case ^Ty_Nil:    return "nil"
    case ^Ty_Ptr:
        return fmt.tprintf("*%s", ty_to_string(v.inner))
    case ^Ty_Tuple:
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, "(")
        for el, i in v.elems {
            if i > 0 do strings.write_string(&sb, ", ")
            strings.write_string(&sb, ty_to_string(el))
        }
        strings.write_string(&sb, ")")
        return strings.to_string(sb)
    case ^Ty_Fn:
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, "(")
        for p, i in v.params {
            if i > 0 do strings.write_string(&sb, ", ")
            strings.write_string(&sb, ty_to_string(p))
        }
        strings.write_string(&sb, ") -> ")
        strings.write_string(&sb, ty_to_string(v.ret))
        return strings.to_string(sb)
    case ^Ty_Adt:
        if len(v.args) == 0 do return v.name
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, v.name)
        strings.write_string(&sb, "<")
        for a, i in v.args {
            if i > 0 do strings.write_string(&sb, ", ")
            strings.write_string(&sb, ty_to_string(a))
        }
        strings.write_string(&sb, ">")
        return strings.to_string(sb)
    case ^Ty_Record:
        if len(v.args) == 0 do return v.name
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, v.name)
        strings.write_string(&sb, "<")
        for a, i in v.args {
            if i > 0 do strings.write_string(&sb, ", ")
            strings.write_string(&sb, ty_to_string(a))
        }
        strings.write_string(&sb, ">")
        return strings.to_string(sb)
    case ^Ty_Var:
        if v.name != "" do return v.name
        return fmt.tprintf("T%d", v.id)
    case ^Ty_Error: return "<error>"
    }
    return "?"
}

// --- Predicates ---

ty_is_int :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Int)
    return ok
}
ty_is_float :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Float)
    return ok
}
ty_is_numeric :: proc(t: Ty) -> bool {
    return ty_is_int(t) || ty_is_float(t)
}
ty_is_bool :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Bool)
    return ok
}
ty_is_unit :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Unit)
    return ok
}
ty_is_error :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Error)
    return ok
}
ty_is_adt :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Adt)
    return ok
}
ty_is_fn :: proc(t: Ty) -> bool {
    _, ok := t.(^Ty_Fn)
    return ok
}

// Structural equality. Untyped numbers are equal to their concrete counterparts
// only when both are untyped; concrete-to-untyped is handled by `ty_assignable`.
ty_equal :: proc(a, b: Ty) -> bool {
    if ty_is_error(a) || ty_is_error(b) do return true
    switch av in a {
    case ^Ty_Int:
        bv, ok := b.(^Ty_Int)
        if !ok do return false
        return av.width == bv.width && av.signed == bv.signed && av.untyped == bv.untyped
    case ^Ty_Float:
        bv, ok := b.(^Ty_Float)
        if !ok do return false
        return av.width == bv.width && av.untyped == bv.untyped
    case ^Ty_Bool:   _, ok := b.(^Ty_Bool);   return ok
    case ^Ty_Char:   _, ok := b.(^Ty_Char);   return ok
    case ^Ty_String:  _, ok := b.(^Ty_String);  return ok
    case ^Ty_Cstring: _, ok := b.(^Ty_Cstring); return ok
    case ^Ty_Unit:    _, ok := b.(^Ty_Unit);    return ok
    case ^Ty_Nil:    _, ok := b.(^Ty_Nil);    return ok
    case ^Ty_Ptr:
        bv, ok := b.(^Ty_Ptr); if !ok do return false
        return ty_equal(av.inner, bv.inner)
    case ^Ty_Tuple:
        bv, ok := b.(^Ty_Tuple); if !ok do return false
        if len(av.elems) != len(bv.elems) do return false
        for el, i in av.elems do if !ty_equal(el, bv.elems[i]) do return false
        return true
    case ^Ty_Fn:
        bv, ok := b.(^Ty_Fn); if !ok do return false
        if len(av.params) != len(bv.params) do return false
        for p, i in av.params do if !ty_equal(p, bv.params[i]) do return false
        return ty_equal(av.ret, bv.ret)
    case ^Ty_Adt:
        bv, ok := b.(^Ty_Adt); if !ok do return false
        if av.name != bv.name do return false
        if len(av.args) != len(bv.args) do return false
        for x, i in av.args do if !ty_equal(x, bv.args[i]) do return false
        return true
    case ^Ty_Record:
        bv, ok := b.(^Ty_Record); if !ok do return false
        if av.name != bv.name do return false
        if len(av.args) != len(bv.args) do return false
        for x, i in av.args do if !ty_equal(x, bv.args[i]) do return false
        return true
    case ^Ty_Var:
        bv, ok := b.(^Ty_Var); if !ok do return false
        return av.id == bv.id
    case ^Ty_Error:
        return true
    }
    return false
}

// Substitute type variables in `t` according to `subst`. Returns a fresh Ty
// tree where every Ty_Var matched in subst is replaced by its mapping.
ty_substitute :: proc(t: Ty, subst: map[int]Ty) -> Ty {
    switch v in t {
    case ^Ty_Var:
        if mapped, ok := subst[v.id]; ok do return mapped
        return t
    case ^Ty_Ptr:
        return ty_ptr(ty_substitute(v.inner, subst))
    case ^Ty_Tuple:
        elems := make([]Ty, len(v.elems))
        for el, i in v.elems do elems[i] = ty_substitute(el, subst)
        return ty_tuple(elems)
    case ^Ty_Fn:
        params := make([]Ty, len(v.params))
        for p, i in v.params do params[i] = ty_substitute(p, subst)
        return ty_fn(params, ty_substitute(v.ret, subst))
    case ^Ty_Adt:
        args := make([]Ty, len(v.args))
        for a, i in v.args do args[i] = ty_substitute(a, subst)
        return ty_adt(v.name, args)
    case ^Ty_Record:
        args := make([]Ty, len(v.args))
        for a, i in v.args do args[i] = ty_substitute(a, subst)
        return ty_record(v.name, args)
    case ^Ty_Int, ^Ty_Float, ^Ty_Bool, ^Ty_Char, ^Ty_String, ^Ty_Cstring,
         ^Ty_Unit, ^Ty_Nil, ^Ty_Error:
        return t
    }
    return t
}

// Match a parameter type against an argument type, learning bindings for any
// Ty_Var encountered in the parameter. Updates `subst` in place. Returns true
// when the match is consistent with any prior bindings, false otherwise.
ty_unify_var :: proc(param: Ty, arg: Ty, subst: ^map[int]Ty) -> bool {
    if v, is_var := param.(^Ty_Var); is_var {
        if prior, exists := subst[v.id]; exists {
            return ty_assignable(arg, prior)
        }
        subst[v.id] = arg
        return true
    }
    switch p in param {
    case ^Ty_Ptr:
        a, ok := arg.(^Ty_Ptr); if !ok do return ty_assignable(arg, param)
        return ty_unify_var(p.inner, a.inner, subst)
    case ^Ty_Tuple:
        a, ok := arg.(^Ty_Tuple); if !ok do return ty_assignable(arg, param)
        if len(p.elems) != len(a.elems) do return false
        for el, i in p.elems do if !ty_unify_var(el, a.elems[i], subst) do return false
        return true
    case ^Ty_Fn:
        a, ok := arg.(^Ty_Fn); if !ok do return ty_assignable(arg, param)
        if len(p.params) != len(a.params) do return false
        for pp, i in p.params do if !ty_unify_var(pp, a.params[i], subst) do return false
        return ty_unify_var(p.ret, a.ret, subst)
    case ^Ty_Adt:
        a, ok := arg.(^Ty_Adt); if !ok do return ty_assignable(arg, param)
        if p.name != a.name do return false
        if len(p.args) != len(a.args) do return false
        for pa, i in p.args do if !ty_unify_var(pa, a.args[i], subst) do return false
        return true
    case ^Ty_Record:
        a, ok := arg.(^Ty_Record); if !ok do return ty_assignable(arg, param)
        if p.name != a.name do return false
        if len(p.args) != len(a.args) do return false
        for pa, i in p.args do if !ty_unify_var(pa, a.args[i], subst) do return false
        return true
    case ^Ty_Int, ^Ty_Float, ^Ty_Bool, ^Ty_Char, ^Ty_String, ^Ty_Cstring,
         ^Ty_Unit, ^Ty_Nil, ^Ty_Error, ^Ty_Var:
        return ty_assignable(arg, param)
    }
    return false
}

// Whether a value of type `actual` can be supplied where type `expected` is
// required. Handles untyped-int / untyped-float promotion and nil-to-pointer.
ty_assignable :: proc(actual, expected: Ty) -> bool {
    if ty_is_error(actual) || ty_is_error(expected) do return true
    if ty_equal(actual, expected) do return true

    if av, aok := actual.(^Ty_Int); aok && av.untyped {
        if _, ok := expected.(^Ty_Int); ok do return true
        if _, ok := expected.(^Ty_Float); ok do return true
    }
    if av, aok := actual.(^Ty_Float); aok && av.untyped {
        if _, ok := expected.(^Ty_Float); ok do return true
    }
    if _, aok := actual.(^Ty_Nil); aok {
        if _, ok := expected.(^Ty_Ptr); ok do return true
    }
    return false
}

// --- Type environment ---

Ty_Env :: struct {
    parent:   ^Ty_Env,
    bindings: map[string]Ty,
}

env_make :: proc(parent: ^Ty_Env, allocator := context.allocator) -> ^Ty_Env {
    e := new(Ty_Env, allocator)
    e.parent = parent
    e.bindings = make(map[string]Ty, allocator)
    return e
}

env_define :: proc(e: ^Ty_Env, name: string, t: Ty) {
    e.bindings[name] = t
}

env_lookup :: proc(e: ^Ty_Env, name: string) -> (Ty, bool) {
    cur := e
    for cur != nil {
        if t, ok := cur.bindings[name]; ok do return t, true
        cur = cur.parent
    }
    return nil, false
}

// --- Resolution: ^Type_Expr -> Ty ---

Ty_Context :: struct {
    enums:    map[string]^Decl_Enum,
    structs:  map[string]^Decl_Struct,
    aliases:  map[string]^Decl_Type_Alias,
    fns:      map[string]^Decl_Fn,
    externs:  map[string]^Decl_External,
    expr_types: map[Expr]Ty,
    errors:   [dynamic]Type_Error,

    fresh_var_id:        int,
    call_instantiations: map[^Expr_Call][]Ty,  // call site -> concrete type args
    path_instantiations: map[^Expr_Path][]Ty,  // standalone variant path -> type args
    adt_instances:       map[string]map[string][]Ty,  // adt name -> key -> type args
    record_instances:    map[string]map[string][]Ty,  // record name -> key -> type args

    variant_index:       map[string][dynamic]Variant_Binding,  // variant name -> enums
    call_enum:           map[^Expr_Call]string,                // unqualified variant call -> enum name
    ident_enum:          map[^Expr_Ident]string,               // unqualified no-arg variant -> enum name
    ident_instantiations: map[^Expr_Ident][]Ty,                // unqualified no-arg variant -> type args
    cstring_literals:    map[^Expr_String_Lit]bool,            // string lits to emit as raw C strings
    current_fn_ret:      Ty,                                   // return type of the fn being checked
    current_type_params: ^map[string]Ty,                       // active type-param env in the fn being checked
    fn_type_var_ids:     map[string][]int,                     // fn name -> Ty_Var ids matching fn.type_params positions
    index_dispatches:    map[^Expr_Index]Index_Dispatch,       // indexing on records/adts -> resolved fn + type args
    binary_dispatches:   map[^Expr_Binary]Index_Dispatch,      // binary op on records/adts -> resolved fn + type args
    unary_dispatches:    map[^Expr_Unary]Index_Dispatch,       // unary op on records/adts -> resolved fn + type args
    assign_dispatches:   map[^Expr_Assign]Index_Dispatch,      // indexed assignment on records/adts -> resolved fn + type args
    operator_table:      map[Operator_Key]string,              // (op, container type name) -> fn name
    packages:            map[string]bool,                      // names of imported packages
    current_pkg:         string,                               // package whose fn is being checked, "" for entry
}

Operator_Key :: struct {
    op:        string,
    type_name: string,
}

Index_Dispatch :: struct {
    fn_name:   string,
    type_args: []Ty,
}

Variant_Binding :: struct {
    enum_decl: ^Decl_Enum,
    variant:   ^Variant_Decl,
}

is_concrete :: proc(t: Ty) -> bool {
    switch v in t {
    case ^Ty_Var: return false
    case ^Ty_Ptr: return is_concrete(v.inner)
    case ^Ty_Tuple:
        for el in v.elems do if !is_concrete(el) do return false
        return true
    case ^Ty_Fn:
        for p in v.params do if !is_concrete(p) do return false
        return is_concrete(v.ret)
    case ^Ty_Adt:
        for a in v.args do if !is_concrete(a) do return false
        return true
    case ^Ty_Record:
        for a in v.args do if !is_concrete(a) do return false
        return true
    case ^Ty_Int, ^Ty_Float, ^Ty_Bool, ^Ty_Char, ^Ty_String, ^Ty_Cstring,
         ^Ty_Unit, ^Ty_Nil, ^Ty_Error:
        return true
    }
    return true
}

adt_instance_key :: proc(name: string, args: []Ty) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, name)
    for arg in args {
        strings.write_string(&sb, "|")
        strings.write_string(&sb, ty_to_string(arg))
    }
    return strings.to_string(sb)
}

intern_adt :: proc(tc: ^Ty_Context, name: string, args: []Ty) {
    if len(args) == 0 do return
    for a in args do if !is_concrete(a) do return
    if _, ok := tc.adt_instances[name]; !ok {
        tc.adt_instances[name] = make(map[string][]Ty)
    }
    inner := &tc.adt_instances[name]
    inner^[adt_instance_key(name, args)] = args
}

intern_record :: proc(tc: ^Ty_Context, name: string, args: []Ty) {
    if len(args) == 0 do return
    for a in args do if !is_concrete(a) do return
    if _, ok := tc.record_instances[name]; !ok {
        tc.record_instances[name] = make(map[string][]Ty)
    }
    inner := &tc.record_instances[name]
    inner^[adt_instance_key(name, args)] = args
}

fresh_ty_var :: proc(tc: ^Ty_Context, name: string) -> Ty {
    tc.fresh_var_id += 1
    return ty_var(tc.fresh_var_id, name)
}

Type_Error :: struct {
    span:    Span,
    message: string,
}

resolve_type :: proc(tc: ^Ty_Context, t: ^Type_Expr, type_params: ^map[string]Ty = nil) -> Ty {
    type_params := type_params
    if type_params == nil do type_params = tc.current_type_params
    if t == nil do return ty_unit()
    switch v in t^ {
    case ^Type_Named:
        return resolve_named_type(tc, v, type_params)
    case ^Type_Ptr:
        return ty_ptr(resolve_type(tc, v.inner, type_params))
    case ^Type_Fn:
        params := make([dynamic]Ty)
        for p in v.params do append(&params, resolve_type(tc, p, type_params))
        ret: Ty = ty_unit()
        if v.ret != nil do ret = resolve_type(tc, v.ret, type_params)
        return ty_fn(params[:], ret)
    case ^Type_Tuple:
        elems := make([dynamic]Ty)
        for el in v.elems do append(&elems, resolve_type(tc, el, type_params))
        return ty_tuple(elems[:])
    case ^Type_Unit:
        return ty_unit()
    }
    return ty_error()
}

resolve_named_type :: proc(tc: ^Ty_Context, n: ^Type_Named, type_params: ^map[string]Ty) -> Ty {
    if len(n.path) == 1 {
        name := n.path[0]
        if type_params != nil {
            if tv, ok := type_params^[name]; ok do return tv
        }
        switch name {
        case "i8":     return ty_int(8,  true)
        case "i16":    return ty_int(16, true)
        case "i32":    return ty_int(32, true)
        case "i64":    return ty_int(64, true)
        case "u8":     return ty_int(8,  false)
        case "u16":    return ty_int(16, false)
        case "u32":    return ty_int(32, false)
        case "u64":    return ty_int(64, false)
        case "f32":    return ty_float(32)
        case "f64":    return ty_float(64)
        case "bool":    return ty_bool()
        case "char":    return ty_char()
        case "string":  return ty_string()
        case "cstring": return ty_cstring()
        case "unit":    return ty_unit()
        case "void":    return ty_unit()
        }
        if _, ok := tc.enums[name]; ok {
            args := make([dynamic]Ty)
            for a in n.args do append(&args, resolve_type(tc, a, type_params))
            intern_adt(tc, name, args[:])
            return ty_adt(name, args[:])
        }
        if _, ok := tc.structs[name]; ok {
            args := make([dynamic]Ty)
            for a in n.args do append(&args, resolve_type(tc, a, type_params))
            intern_record(tc, name, args[:])
            return ty_record(name, args[:])
        }
        if alias, ok := tc.aliases[name]; ok {
            return resolve_type(tc, alias.target, type_params)
        }
        append(&tc.errors, Type_Error{
            span = n.span,
            message = fmt.tprintf("unknown type `%s`", name),
        })
        return ty_error()
    }
    append(&tc.errors, Type_Error{
        span = n.span,
        message = "module-qualified types are not yet supported",
    })
    return ty_error()
}
