package main

import "core:fmt"
import "core:strings"

// Bidirectional type checker for Stage A.
// Runs after parsing and before codegen. Populates tc.expr_types so that
// later passes can read the resolved type of each expression. Errors are
// collected in tc.errors with source spans.

type_check_file :: proc(f: File, allocator := context.allocator) -> ^Ty_Context {
    tc := new(Ty_Context, allocator)
    tc.enums   = make(map[string]^Decl_Enum, allocator)
    tc.structs = make(map[string]^Decl_Struct, allocator)
    tc.aliases = make(map[string]^Decl_Type_Alias, allocator)
    tc.fns     = make(map[string]^Decl_Fn, allocator)
    tc.externs = make(map[string]^Decl_External, allocator)
    tc.expr_types = make(map[Expr]Ty, allocator)
    tc.errors  = make([dynamic]Type_Error, allocator)
    tc.call_instantiations = make(map[^Expr_Call][]Ty, allocator)
    tc.path_instantiations = make(map[^Expr_Path][]Ty, allocator)
    tc.adt_instances    = make(map[string]map[string][]Ty, allocator)
    tc.record_instances = make(map[string]map[string][]Ty, allocator)
    tc.variant_index    = make(map[string][dynamic]Variant_Binding, allocator)
    tc.call_enum        = make(map[^Expr_Call]string, allocator)
    tc.ident_enum       = make(map[^Expr_Ident]string, allocator)
    tc.ident_instantiations = make(map[^Expr_Ident][]Ty, allocator)
    tc.cstring_literals = make(map[^Expr_String_Lit]bool, allocator)
    tc.fn_type_var_ids = make(map[string][]int, allocator)
    tc.index_dispatches = make(map[^Expr_Index]Index_Dispatch, allocator)
    tc.binary_dispatches = make(map[^Expr_Binary]Index_Dispatch, allocator)
    tc.unary_dispatches = make(map[^Expr_Unary]Index_Dispatch, allocator)
    tc.assign_dispatches = make(map[^Expr_Assign]Index_Dispatch, allocator)
    tc.operator_table = make(map[Operator_Key]string, allocator)
    tc.packages = make(map[string]bool, allocator)

    register_builtin_decls(tc)
    register_decls(tc, f)
    build_variant_index(tc)
    register_operator_decls(tc)
    check_decls(tc, f)
    return tc
}

// Walk all registered fns and bind each `@operator(...)` tag to its
// container type. The container type is extracted from the first parameter,
// which must be a pointer to a named (record or ADT) type.
register_operator_decls :: proc(tc: ^Ty_Context) {
    for _, fn in tc.fns {
        if fn.operator == "" do continue
        type_name, ok := operator_container_name(fn)
        if !ok {
            emit_error(tc, fn.span, fmt.tprintf("`@operator(\"%s\")` requires the first parameter to be a pointer to a named type", fn.operator))
            continue
        }
        key := Operator_Key{op = fn.operator, type_name = type_name}
        if existing, dup := tc.operator_table[key]; dup {
            emit_error(tc, fn.span, fmt.tprintf("operator `%s` already defined for `%s` by `%s`", fn.operator, type_name, existing))
            continue
        }
        tc.operator_table[key] = fn.name
    }
}

operator_container_name :: proc(fn: ^Decl_Fn) -> (string, bool) {
    if len(fn.params) == 0 do return "", false
    pt := fn.params[0].type
    if pt == nil do return "", false
    ptr, is_ptr := pt^.(^Type_Ptr)
    if !is_ptr do return "", false
    if ptr.inner == nil do return "", false
    named, is_named := ptr.inner^.(^Type_Named)
    if !is_named do return "", false
    if len(named.path) != 1 do return "", false
    return named.path[0], true
}

// Construct the built-in Option<T> and Result<T, E> enum declarations and
// register them as if the user had written them. Their variant constructors
// (Some, None, Ok, Err) are then in scope unqualified.
register_builtin_decls :: proc(tc: ^Ty_Context) {
    tc.enums["Option"] = make_builtin_option()
    tc.enums["Result"] = make_builtin_result()
}

make_named_type :: proc(name: string) -> ^Type_Expr {
    n := new(Type_Named)
    segs := make([]string, 1); segs[0] = name
    n.path = segs
    te := new(Type_Expr)
    te^ = n
    return te
}

make_builtin_option :: proc() -> ^Decl_Enum {
    d := new(Decl_Enum)
    d.name = "Option"
    tp := make([]string, 1); tp[0] = "T"
    d.type_params = tp

    some_pos := make([]^Type_Expr, 1)
    some_pos[0] = make_named_type("T")

    variants := make([]Variant_Decl, 2)
    variants[0] = Variant_Decl{name = "Some", kind = .Positional, pos = some_pos}
    variants[1] = Variant_Decl{name = "None", kind = .None}
    d.variants = variants
    return d
}

make_builtin_result :: proc() -> ^Decl_Enum {
    d := new(Decl_Enum)
    d.name = "Result"
    tp := make([]string, 2); tp[0] = "T"; tp[1] = "E"
    d.type_params = tp

    ok_pos := make([]^Type_Expr, 1)
    ok_pos[0] = make_named_type("T")
    err_pos := make([]^Type_Expr, 1)
    err_pos[0] = make_named_type("E")

    variants := make([]Variant_Decl, 2)
    variants[0] = Variant_Decl{name = "Ok",  kind = .Positional, pos = ok_pos}
    variants[1] = Variant_Decl{name = "Err", kind = .Positional, pos = err_pos}
    d.variants = variants
    return d
}

build_variant_index :: proc(tc: ^Ty_Context) {
    for _, enum_decl in tc.enums {
        for i in 0..<len(enum_decl.variants) {
            name := enum_decl.variants[i].name
            list, exists := tc.variant_index[name]
            if !exists do list = make([dynamic]Variant_Binding)
            append(&list, Variant_Binding{enum_decl = enum_decl, variant = &enum_decl.variants[i]})
            tc.variant_index[name] = list
        }
    }
}

variant_lookup_unique :: proc(tc: ^Ty_Context, name: string) -> (Variant_Binding, bool) {
    list, ok := tc.variant_index[name]
    if !ok do return Variant_Binding{}, false
    if len(list) != 1 do return Variant_Binding{}, false
    return list[0], true
}

is_unshadowed_builtin :: proc(tc: ^Ty_Context, env: ^Ty_Env, name: string) -> bool {
    switch name {
    case "println", "size_of", "hash", "len":
    case:
        return false
    }
    if _, ok := env_lookup(env, name); ok do return false
    if _, ok := tc.fns[name]; ok do return false
    if _, ok := tc.externs[name]; ok do return false
    if _, ok := resolve_pkg_short(tc, name); ok do return false
    return true
}

pkg_of_qualified :: proc(tc: ^Ty_Context, qualified: string) -> string {
    for i in 0..<len(qualified) {
        if qualified[i] == '_' {
            head := qualified[:i]
            if _, ok := tc.packages[head]; ok do return head
        }
    }
    return ""
}

resolve_pkg_short :: proc(tc: ^Ty_Context, name: string) -> (string, bool) {
    if tc.current_pkg == "" do return "", false
    qualified := fmt.tprintf("%s_%s", tc.current_pkg, name)
    if _, ok := tc.fns[qualified]; ok do return qualified, true
    if _, ok := tc.externs[qualified]; ok do return qualified, true
    return "", false
}

is_reserved_builtin_name :: proc(name: string) -> bool {
    switch name {
    case "println", "size_of", "hash", "len":
        return true
    }
    return false
}

register_decls :: proc(tc: ^Ty_Context, f: File) {
    for p in f.packages do tc.packages[p] = true
    for d in f.decls {
        switch v in d {
        case ^Decl_Import:
            pkg_name := v.alias
            if pkg_name == "" do pkg_name = v.path[len(v.path)-1]
            tc.packages[pkg_name] = true
        case ^Decl_Link:
        case ^Decl_Const:
        case ^Decl_Enum:       tc.enums[v.name]   = v
        case ^Decl_Struct:     tc.structs[v.name] = v
        case ^Decl_Type_Alias: tc.aliases[v.name] = v
        case ^Decl_Fn:
            if is_reserved_builtin_name(v.name) {
                emit_error(tc, v.span, fmt.tprintf("`%s` is a reserved builtin name; pick a different name or put it inside a package", v.name))
            }
            tc.fns[v.name] = v
        case ^Decl_External:
            if is_reserved_builtin_name(v.name) {
                emit_error(tc, v.span, fmt.tprintf("`%s` is a reserved builtin name; pick a different name or annotate with `@link_name`", v.name))
            }
            tc.externs[v.name] = v
        }
    }
}

check_decls :: proc(tc: ^Ty_Context, f: File) {
    for d in f.decls {
        switch v in d {
        case ^Decl_Fn:
            check_fn(tc, v)
        case ^Decl_Const:
            check_const(tc, v)
        case ^Decl_Import, ^Decl_Link, ^Decl_Enum, ^Decl_Struct,
             ^Decl_Type_Alias, ^Decl_External:
                                                                 // structural decls only; nothing to type-check
        }
    }
}

check_fn :: proc(tc: ^Ty_Context, d: ^Decl_Fn) {
    saved_pkg := tc.current_pkg
    tc.current_pkg = pkg_of_qualified(tc, d.name)
    defer tc.current_pkg = saved_pkg

    type_params: map[string]Ty
    has_params := len(d.type_params) > 0
    if has_params {
        type_params = make(map[string]Ty)
        var_ids := make([]int, len(d.type_params))
        for tp, i in d.type_params {
            tv := fresh_ty_var(tc, tp)
            type_params[tp] = tv
            if t, ok := tv.(^Ty_Var); ok do var_ids[i] = t.id
        }
        tc.fn_type_var_ids[d.name] = var_ids
    }
    tp_ptr: ^map[string]Ty = nil
    if has_params do tp_ptr = &type_params

    env := env_make(nil)
    for p in d.params {
        env_define(env, p.name, resolve_type(tc, p.type, tp_ptr))
    }
    ret_ty: Ty
    if d.ret != nil {
        ret_ty = resolve_type(tc, d.ret, tp_ptr)
    } else {
        ret_ty = ty_unit()
    }
    saved_ret := tc.current_fn_ret
    tc.current_fn_ret = ret_ty
    defer tc.current_fn_ret = saved_ret
    saved_tp := tc.current_type_params
    tc.current_type_params = tp_ptr
    defer tc.current_type_params = saved_tp
    if d.body != nil {
        check_block(tc, env, d.body, ret_ty)
    }
}

check_const :: proc(tc: ^Ty_Context, d: ^Decl_Const) {
    if d.type != nil {
        expected := resolve_type(tc, d.type)
        check(tc, env_make(nil), d.value, expected)
    } else {
        synth(tc, env_make(nil), d.value)
    }
}

// --- Blocks ---

check_block :: proc(tc: ^Ty_Context, parent: ^Ty_Env, b: ^Expr_Block, expected: Ty) -> Ty {
    env := env_make(parent)
    for s in b.stmts {
        check_stmt(tc, env, s)
    }
    if b.tail != nil {
        return check(tc, env, b.tail, expected)
    }
    if !ty_is_unit(expected) {
        emit_error(tc, b.span, fmt.tprintf("block has no value but %s is expected", ty_to_string(expected)))
    }
    return ty_unit()
}

synth_block :: proc(tc: ^Ty_Context, parent: ^Ty_Env, b: ^Expr_Block) -> Ty {
    env := env_make(parent)
    for s in b.stmts {
        check_stmt(tc, env, s)
    }
    if b.tail != nil {
        return synth(tc, env, b.tail)
    }
    return ty_unit()
}

check_stmt :: proc(tc: ^Ty_Context, env: ^Ty_Env, s: Stmt) {
    switch v in s {
    case ^Stmt_Let:
        check_let_stmt(tc, env, v.name, v.type, v.value)
    case ^Stmt_Var:
        check_let_stmt(tc, env, v.name, v.type, v.value)
    case ^Stmt_Let_Else:
        check_let_else_stmt(tc, env, v)
    case ^Stmt_Expr:
        synth(tc, env, v.expr)
    }
}

check_let_else_stmt :: proc(tc: ^Ty_Context, env: ^Ty_Env, s: ^Stmt_Let_Else) {
    scrut := synth(tc, env, s.value)
    scrut_adt := scrut
    if ptr, is_ptr := scrut.(^Ty_Ptr); is_ptr do scrut_adt = ptr.inner
    adt, is_adt := scrut_adt.(^Ty_Adt)
    if !is_adt && !ty_is_error(scrut) {
        emit_error(tc, s.span, fmt.tprintf("let-else requires an ADT value, got %s", ty_to_string(scrut)))
    }
    if is_adt {
        check_pattern(tc, env, s.pat, adt)
    }
    inner := env_make(env)
    for s2 in s.else_block.stmts do check_stmt(tc, inner, s2)
    if s.else_block.tail != nil do synth(tc, inner, s.else_block.tail)
    if !block_diverges(s.else_block) {
        emit_error(tc, s.span, "let-else else block must diverge (end with `return`)")
    }
}

// A block diverges when control flow cannot fall off the end. Stage A
// recognises a trailing `return` and an unconditional `return` in tail
// position. Future work: also recognise calls to functions marked never-return.
block_diverges :: proc(b: ^Expr_Block) -> bool {
    if b == nil do return false
    if b.tail != nil {
        if _, ok := b.tail.(^Expr_Return); ok do return true
    }
    if len(b.stmts) > 0 {
        last := b.stmts[len(b.stmts)-1]
        if es, ok := last.(^Stmt_Expr); ok {
            if _, ret_ok := es.expr.(^Expr_Return); ret_ok do return true
        }
    }
    return false
}

check_let_stmt :: proc(tc: ^Ty_Context, env: ^Ty_Env, name: string, ann: ^Type_Expr, value: Expr) {
    if ann != nil {
        expected := resolve_type(tc, ann)
        check(tc, env, value, expected)
        env_define(env, name, expected)
        return
    }
    t := synth(tc, env, value)
    if t_int, is_int := t.(^Ty_Int); is_int && t_int.untyped {
        t = ty_int(64, true)
    }
    if t_flt, is_flt := t.(^Ty_Float); is_flt && t_flt.untyped {
        t = ty_float(64)
    }
    env_define(env, name, t)
}

// --- Bidirectional core ---

check :: proc(tc: ^Ty_Context, env: ^Ty_Env, e: Expr, expected: Ty) -> Ty {
    #partial switch v in e {
    case ^Expr_Int_Lit:
        if ty_is_int(expected) || ty_is_float(expected) {
            tc.expr_types[e] = expected
            return expected
        }
    case ^Expr_Float_Lit:
        if ty_is_float(expected) {
            tc.expr_types[e] = expected
            return expected
        }
    case ^Expr_String_Lit:
        if _, is_cstr := expected.(^Ty_Cstring); is_cstr {
            tc.expr_types[e] = expected
            tc.cstring_literals[v] = true
            return expected
        }
    case ^Expr_Block:
        t := check_block(tc, env, v, expected)
        tc.expr_types[e] = t
        return t
    case ^Expr_If:
        check(tc, env, v.cond, ty_bool())
        check(tc, env, v.then_b, expected)
        if v.else_b != nil {
            check(tc, env, v.else_b, expected)
        } else if !ty_is_unit(expected) {
            emit_error(tc, v.span, fmt.tprintf("`if` without `else` produces unit, but %s is expected", ty_to_string(expected)))
        }
        tc.expr_types[e] = expected
        return expected
    case ^Expr_Match:
        check_match(tc, env, v, expected)
        tc.expr_types[e] = expected
        return expected
    case ^Expr_Return:
        if v.value != nil {
            if tc.current_fn_ret != nil {
                check(tc, env, v.value, tc.current_fn_ret)
            } else {
                synth(tc, env, v.value)
            }
        }
        return expected
    case ^Expr_Path:
        if t, ok := check_variant_path(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
    case ^Expr_Call:
        if t, ok := check_variant_call_expr(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
        if t, ok := check_unqualified_variant_call(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
        if t, ok := check_generic_fn_call(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
    case ^Expr_Ident:
        if t, ok := check_unqualified_no_arg_variant(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
    case ^Expr_Record:
        if t, ok := check_record_literal(tc, env, v, expected); ok {
            tc.expr_types[e] = t
            return t
        }
    }
    actual := synth(tc, env, e)
    if !ty_assignable(actual, expected) {
        emit_error(tc, expr_span(e), fmt.tprintf("expected %s, got %s", ty_to_string(expected), ty_to_string(actual)))
    }
    return expected
}

check_record_literal :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Record, expected: Ty) -> (Ty, bool) {
    if v.type == nil do return nil, false
    tn, ok := v.type^.(^Type_Named)
    if !ok || len(tn.path) != 1 do return nil, false
    name := tn.path[0]
    decl, found := tc.structs[name]
    if !found do return nil, false
    if len(decl.type_params) == 0 do return nil, false
    if len(tn.args) > 0 do return nil, false

    expected_rec, is_rec := expected.(^Ty_Record)
    if !is_rec do return nil, false
    if expected_rec.name != name do return nil, false
    if len(expected_rec.args) != len(decl.type_params) do return nil, false

    params_env := make(map[string]Ty)
    for tp, i in decl.type_params {
        params_env[tp] = expected_rec.args[i]
    }
    field_types := make(map[string]Ty)
    for fld in decl.fields {
        field_types[fld.name] = resolve_type(tc, fld.type, &params_env)
    }
    seen := make(map[string]bool)
    for fld in v.fields {
        expected_ft, exists := field_types[fld.name]
        if !exists {
            emit_error(tc, v.span, fmt.tprintf("record `%s` has no field `%s`", name, fld.name))
            synth(tc, env, fld.value)
            continue
        }
        check(tc, env, fld.value, expected_ft)
        seen[fld.name] = true
    }
    if v.base != nil {
        base_ty := synth(tc, env, v.base)
        if !ty_assignable(base_ty, expected) {
            emit_error(tc, v.span, fmt.tprintf("partial update base must be %s, got %s", ty_to_string(expected), ty_to_string(base_ty)))
        }
    } else {
        for fld in decl.fields {
            if !seen[fld.name] {
                emit_error(tc, v.span, fmt.tprintf("missing field `%s` in record literal `%s`", fld.name, name))
            }
        }
    }
    intern_record(tc, name, expected_rec.args)
    return expected, true
}

check_generic_fn_call :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call, expected: Ty) -> (Ty, bool) {
    if path, is_path := v.callee.(^Expr_Path); is_path && len(path.segs) == 2 {
        if _, in_pkg := tc.packages[path.segs[0]]; in_pkg {
            qualified := fmt.tprintf("%s_%s", path.segs[0], path.segs[1])
            _, in_fns := tc.fns[qualified]
            _, in_externs := tc.externs[qualified]
            if in_fns || in_externs {
                fake_id := new(Expr_Ident)
                fake_id.span = path.span; fake_id.name = qualified
                v.callee = fake_id
            }
        }
    }
    id, is_id := v.callee.(^Expr_Ident)
    if !is_id do return nil, false
    if _, in_env := env_lookup(env, id.name); in_env do return nil, false
    if _, in_fns := tc.fns[id.name]; !in_fns {
        if qualified, qok := resolve_pkg_short(tc, id.name); qok {
            id.name = qualified
        }
    }
    fn_decl, ok := tc.fns[id.name]
    if !ok do return nil, false
    if len(fn_decl.type_params) == 0 do return nil, false

    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok2 := tv.(^Ty_Var); ok2 do fresh_var_ids[i] = t.id
    }

    param_tys := make([]Ty, len(fn_decl.params))
    for p, i in fn_decl.params {
        param_tys[i] = resolve_type(tc, p.type, &params_env)
    }
    ret_ty: Ty = ty_unit()
    if fn_decl.ret != nil do ret_ty = resolve_type(tc, fn_decl.ret, &params_env)

    if len(v.args) != len(param_tys) {
        emit_error(tc, v.span, fmt.tprintf("function `%s` expects %d argument(s), got %d",
            fn_decl.name, len(param_tys), len(v.args)))
        for a in v.args do synth(tc, env, a)
        return ty_error(), true
    }

    subst := make(map[int]Ty)
    ty_unify_var(ret_ty, expected, &subst)
    for arg, i in v.args {
        actual := synth(tc, env, arg)
        ty_unify_var(param_tys[i], actual, &subst)
    }

    instantiation := make([]Ty, len(fresh_var_ids))
    for fid, i in fresh_var_ids {
        if mapped, ok2 := subst[fid]; ok2 {
            mapped = finalise_untyped(mapped)
            subst[fid] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }
    tc.call_instantiations[v] = instantiation
    return ty_substitute(ret_ty, subst), true
}

check_unqualified_no_arg_variant :: proc(tc: ^Ty_Context, env: ^Ty_Env, id: ^Expr_Ident, expected: Ty) -> (Ty, bool) {
    if _, in_env := env_lookup(env, id.name); in_env do return nil, false
    vb, ok := variant_lookup_unique(tc, id.name)
    if !ok do return nil, false
    if vb.variant.kind != .None do return nil, false
    if len(vb.enum_decl.type_params) == 0 {
        result := ty_adt(vb.enum_decl.name, make([]Ty, 0))
        if !ty_assignable(result, expected) do return nil, false
        tc.ident_enum[id] = vb.enum_decl.name
        return result, true
    }
    expected_adt, is_adt := expected.(^Ty_Adt)
    if !is_adt do return nil, false
    if expected_adt.name != vb.enum_decl.name do return nil, false
    if len(expected_adt.args) != len(vb.enum_decl.type_params) do return nil, false
    intern_adt(tc, vb.enum_decl.name, expected_adt.args)
    tc.ident_enum[id] = vb.enum_decl.name
    tc.ident_instantiations[id] = expected_adt.args
    return expected, true
}

check_unqualified_variant_call :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call, expected: Ty) -> (Ty, bool) {
    id, is_id := v.callee.(^Expr_Ident)
    if !is_id do return nil, false
    if _, in_env := env_lookup(env, id.name); in_env do return nil, false
    vb, ok := variant_lookup_unique(tc, id.name)
    if !ok do return nil, false
    if len(vb.enum_decl.type_params) == 0 {
        result := synth_variant_call(tc, env, v, vb.enum_decl, vb.variant)
        tc.call_enum[v] = vb.enum_decl.name
        if !ty_assignable(result, expected) {
            emit_error(tc, v.span, fmt.tprintf("expected %s, got %s", ty_to_string(expected), ty_to_string(result)))
        }
        return result, true
    }
    expected_adt, is_adt := expected.(^Ty_Adt)
    if !is_adt do return nil, false
    if expected_adt.name != vb.enum_decl.name do return nil, false
    if len(expected_adt.args) != len(vb.enum_decl.type_params) do return nil, false

    params_env := make(map[string]Ty)
    for tp, i in vb.enum_decl.type_params {
        params_env[tp] = expected_adt.args[i]
    }

    param_tys: []Ty
    if vb.variant.kind == .Positional {
        param_tys = make([]Ty, len(vb.variant.pos))
        for t, i in vb.variant.pos do param_tys[i] = resolve_type(tc, t, &params_env)
    } else if vb.variant.kind == .Named {
        param_tys = make([]Ty, len(vb.variant.named))
        for fld, i in vb.variant.named do param_tys[i] = resolve_type(tc, fld.type, &params_env)
    }

    if len(v.args) != len(param_tys) {
        emit_error(tc, v.span, fmt.tprintf("`%s` expects %d argument(s), got %d", id.name, len(param_tys), len(v.args)))
        for a in v.args do synth(tc, env, a)
        return ty_error(), true
    }
    for arg, i in v.args {
        check(tc, env, arg, param_tys[i])
    }
    type_args := make([]Ty, len(vb.enum_decl.type_params))
    for tp, i in vb.enum_decl.type_params do type_args[i] = expected_adt.args[i]
    tc.call_instantiations[v] = type_args
    tc.call_enum[v] = vb.enum_decl.name
    intern_adt(tc, vb.enum_decl.name, type_args)
    return expected, true
}

// Try a bidirectional check for a no-arg variant path. Returns ok=false if
// the path is not a variant of a generic ADT, leaving the caller to fall back
// to synth-and-compare.
check_variant_path :: proc(tc: ^Ty_Context, env: ^Ty_Env, p: ^Expr_Path, expected: Ty) -> (Ty, bool) {
    if len(p.segs) != 2 do return nil, false
    enum_decl, ok := tc.enums[p.segs[0]]
    if !ok do return nil, false
    if len(enum_decl.type_params) == 0 do return nil, false

    expected_adt, is_adt := expected.(^Ty_Adt)
    if !is_adt do return nil, false
    if expected_adt.name != enum_decl.name do return nil, false
    if len(expected_adt.args) != len(enum_decl.type_params) do return nil, false

    found := false
    for variant in enum_decl.variants {
        if variant.name == p.segs[1] && variant.kind == .None {
            found = true
            break
        }
    }
    if !found do return nil, false

    intern_adt(tc, enum_decl.name, expected_adt.args)
    tc.path_instantiations[p] = expected_adt.args
    return expected, true
}

// Try a bidirectional check for a variant constructor call against an
// expected ADT type. The expected type pins the type parameters before the
// arguments are checked, so untyped literals land on the right concrete type.
check_variant_call_expr :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call, expected: Ty) -> (Ty, bool) {
    path, is_path := v.callee.(^Expr_Path)
    if !is_path do return nil, false
    if len(path.segs) != 2 do return nil, false
    enum_decl, ok := tc.enums[path.segs[0]]
    if !ok do return nil, false
    if len(enum_decl.type_params) == 0 do return nil, false

    expected_adt, is_adt := expected.(^Ty_Adt)
    if !is_adt do return nil, false
    if expected_adt.name != enum_decl.name do return nil, false
    if len(expected_adt.args) != len(enum_decl.type_params) do return nil, false

    variant: ^Variant_Decl
    for i in 0..<len(enum_decl.variants) {
        if enum_decl.variants[i].name == path.segs[1] {
            variant = &enum_decl.variants[i]
            break
        }
    }
    if variant == nil do return nil, false

    params_env := make(map[string]Ty)
    for tp, i in enum_decl.type_params {
        params_env[tp] = expected_adt.args[i]
    }

    param_tys: []Ty
    if variant.kind == .Positional {
        param_tys = make([]Ty, len(variant.pos))
        for t, i in variant.pos do param_tys[i] = resolve_type(tc, t, &params_env)
    } else if variant.kind == .Named {
        param_tys = make([]Ty, len(variant.named))
        for fld, i in variant.named do param_tys[i] = resolve_type(tc, fld.type, &params_env)
    }

    if len(v.args) != len(param_tys) {
        emit_error(tc, v.span, fmt.tprintf("`%s.%s` expects %d argument(s), got %d",
            enum_decl.name, variant.name, len(param_tys), len(v.args)))
        for a in v.args do synth(tc, env, a)
        return ty_error(), true
    }

    for arg, i in v.args {
        check(tc, env, arg, param_tys[i])
    }

    type_args := make([]Ty, len(enum_decl.type_params))
    for tp, i in enum_decl.type_params do type_args[i] = expected_adt.args[i]

    tc.call_instantiations[v] = type_args
    intern_adt(tc, enum_decl.name, type_args)
    return expected, true
}

synth :: proc(tc: ^Ty_Context, env: ^Ty_Env, e: Expr) -> Ty {
    result := synth_impl(tc, env, e)
    tc.expr_types[e] = result
    return result
}

synth_impl :: proc(tc: ^Ty_Context, env: ^Ty_Env, e: Expr) -> Ty {
    switch v in e {
    case ^Expr_Int_Lit:
        return ty_untyped_int()
    case ^Expr_Float_Lit:
        return ty_untyped_float()
    case ^Expr_String_Lit:
        return ty_string()
    case ^Expr_Char_Lit:
        return ty_char()
    case ^Expr_Bool_Lit:
        return ty_bool()
    case ^Expr_Nil_Lit:
        return ty_nil()
    case ^Expr_Ident:
        return synth_ident(tc, env, v)
    case ^Expr_Path:
        return synth_path(tc, env, v)
    case ^Expr_Unary:
        return synth_unary(tc, env, v)
    case ^Expr_Binary:
        return synth_binary(tc, env, v)
    case ^Expr_Assign:
        return synth_assign(tc, env, v)
    case ^Expr_Call:
        return synth_call(tc, env, v)
    case ^Expr_Field:
        return synth_field(tc, env, v)
    case ^Expr_Index:
        return synth_index(tc, env, v)
    case ^Expr_Cast:
        synth(tc, env, v.value)
        return resolve_type(tc, v.target)
    case ^Expr_New:
        return synth(tc, env, v.value)
    case ^Expr_Try:
        return synth_try(tc, env, v)
    case ^Expr_Size_Of:
        resolve_type(tc, v.target)
        return ty_int(64, true)
    case ^Expr_Tuple:
        elems := make([dynamic]Ty)
        for el in v.elems do append(&elems, synth(tc, env, el))
        return ty_tuple(elems[:])
    case ^Expr_Record:
        return synth_record(tc, env, v)
    case ^Expr_Closure:
        return synth_closure(tc, env, v)
    case ^Expr_Block:
        return synth_block(tc, env, v)
    case ^Expr_If:
        return synth_if(tc, env, v)
    case ^Expr_Match:
        return synth_match(tc, env, v)
    case ^Expr_While:
        check(tc, env, v.cond, ty_bool())
        check_block(tc, env, v.body, ty_unit())
        return ty_unit()
    case ^Expr_For:
        synth(tc, env, v.iter)
        inner := env_make(env)
        env_define(inner, v.binding, ty_int(64, true))
        check_block(tc, inner, v.body, ty_unit())
        return ty_unit()
    case ^Expr_Return:
        if v.value != nil {
            if tc.current_fn_ret != nil {
                check(tc, env, v.value, tc.current_fn_ret)
            } else {
                synth(tc, env, v.value)
            }
        }
        return ty_unit()
    case ^Expr_Defer:
        synth(tc, env, v.body)
        return ty_unit()
    }
    return ty_error()
}

// --- Specific synth helpers ---

synth_ident :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Ident) -> Ty {
    if t, ok := env_lookup(env, v.name); ok do return t
    if fn, ok := tc.fns[v.name]; ok {
        return fn_decl_to_ty(tc, fn)
    }
    if fn, ok := tc.externs[v.name]; ok {
        return extern_to_ty(tc, fn)
    }
    if qualified, ok := resolve_pkg_short(tc, v.name); ok {
        v.name = qualified
        return synth_ident(tc, env, v)
    }
    if vb, ok := variant_lookup_unique(tc, v.name); ok && vb.variant.kind == .None {
        if len(vb.enum_decl.type_params) > 0 {
            emit_error(tc, v.span, fmt.tprintf("cannot infer type of `%s`; add an annotation, e.g. `: %s<...>`", v.name, vb.enum_decl.name))
            return ty_error()
        }
        tc.ident_enum[v] = vb.enum_decl.name
        return ty_adt(vb.enum_decl.name, make([]Ty, 0))
    }
    emit_error(tc, v.span, fmt.tprintf("undefined name `%s`", v.name))
    return ty_error()
}

fn_decl_to_ty :: proc(tc: ^Ty_Context, fn: ^Decl_Fn) -> Ty {
    params := make([dynamic]Ty)
    for p in fn.params do append(&params, resolve_type(tc, p.type))
    ret: Ty = ty_unit()
    if fn.ret != nil do ret = resolve_type(tc, fn.ret)
    return ty_fn(params[:], ret)
}

extern_to_ty :: proc(tc: ^Ty_Context, fn: ^Decl_External) -> Ty {
    params := make([dynamic]Ty)
    for p in fn.params do append(&params, resolve_type(tc, p.type))
    ret: Ty = ty_unit()
    if fn.ret != nil do ret = resolve_type(tc, fn.ret)
    return ty_fn(params[:], ret)
}

synth_path :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Path) -> Ty {
    if len(v.segs) == 2 {
        if e, ok := tc.enums[v.segs[0]]; ok {
            for i in 0..<len(e.variants) {
                if e.variants[i].name == v.segs[1] {
                    if e.variants[i].kind == .None {
                        return ty_adt(e.name, make([]Ty, 0))
                    }
                    return variant_constructor_ty(tc, e, &e.variants[i])
                }
            }
            emit_error(tc, v.span, fmt.tprintf("`%s` has no variant `%s`", e.name, v.segs[1]))
            return ty_error()
        }
    }
    if t, in_scope := env_lookup(env, v.segs[0]); in_scope {
        current := t
        for i in 1..<len(v.segs) {
            current = field_type_of(tc, current, v.segs[i], v.span)
        }
        return current
    }
    return ty_error()
}

field_type_of :: proc(tc: ^Ty_Context, base: Ty, field: string, span: Span) -> Ty {
    rec_ty := base
    if ptr, is_ptr := base.(^Ty_Ptr); is_ptr do rec_ty = ptr.inner
    if rec, is_rec := rec_ty.(^Ty_Record); is_rec {
        if decl, found := tc.structs[rec.name]; found {
            type_params: map[string]Ty
            tp_ptr: ^map[string]Ty = nil
            if len(decl.type_params) > 0 && len(rec.args) == len(decl.type_params) {
                type_params = make(map[string]Ty)
                for tp, i in decl.type_params {
                    type_params[tp] = rec.args[i]
                }
                tp_ptr = &type_params
            }
            for fld in decl.fields {
                if fld.name == field do return resolve_type(tc, fld.type, tp_ptr)
            }
            emit_error(tc, span, fmt.tprintf("record `%s` has no field `%s`", rec.name, field))
            return ty_error()
        }
    }
    if ty_is_error(base) do return ty_error()
    emit_error(tc, span, fmt.tprintf("cannot access field `%s` on %s", field, ty_to_string(base)))
    return ty_error()
}

variant_constructor_ty :: proc(tc: ^Ty_Context, e: ^Decl_Enum, variant: ^Variant_Decl) -> Ty {
    adt_ty := ty_adt(e.name, make([]Ty, 0))
    if variant.kind == .Positional {
        params := make([dynamic]Ty)
        for t in variant.pos do append(&params, resolve_type(tc, t))
        return ty_fn(params[:], adt_ty)
    }
    params := make([dynamic]Ty)
    for fld in variant.named do append(&params, resolve_type(tc, fld.type))
    return ty_fn(params[:], adt_ty)
}

synth_unary :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Unary) -> Ty {
    t := synth(tc, env, v.rhs)
    switch v.op {
    case .Neg:
        if op_name, ok := operand_container_name(t); ok {
            if dispatched, found := try_dispatch_unary(tc, env, v, "unary-", op_name); found {
                return dispatched
            }
        }
        if !ty_is_numeric(t) {
            emit_error(tc, v.span, fmt.tprintf("unary `-` requires a numeric operand, got %s", ty_to_string(t)))
            return ty_error()
        }
        return t
    case .Not:
        if op_name, ok := operand_container_name(t); ok {
            if dispatched, found := try_dispatch_unary(tc, env, v, "unary!", op_name); found {
                return dispatched
            }
        }
        if !ty_is_bool(t) {
            emit_error(tc, v.span, fmt.tprintf("`!` requires a bool, got %s", ty_to_string(t)))
            return ty_error()
        }
        return ty_bool()
    case .Deref:
        if ptr, ok := t.(^Ty_Ptr); ok do return ptr.inner
        emit_error(tc, v.span, fmt.tprintf("cannot dereference non-pointer type %s", ty_to_string(t)))
        return ty_error()
    case .Addr:
        return ty_ptr(t)
    }
    return ty_error()
}

binary_op_lookup_name :: proc(op: Binary_Op) -> (string, bool) {
    switch op {
    case .Add: return "+",  true
    case .Sub: return "-",  true
    case .Mul: return "*",  true
    case .Div: return "/",  true
    case .Mod: return "%",  true
    case .Eq:  return "==", true
    case .Ne:  return "!=", true
    case .Lt:  return "<",  true
    case .Gt:  return ">",  true
    case .Le:  return "<=", true
    case .Ge:  return ">=", true
    case .And, .Or, .Range, .Range_Inclusive:
        return "", false
    }
    return "", false
}

synth_binary :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Binary) -> Ty {
    lhs := synth(tc, env, v.lhs)
    rhs := synth(tc, env, v.rhs)

    if op_str, dispatchable := binary_op_lookup_name(v.op); dispatchable {
        lhs_name, lhs_ok := operand_container_name(lhs)
        rhs_name, rhs_ok := operand_container_name(rhs)
        container := ""
        if lhs_ok {
            container = lhs_name
        } else if rhs_ok {
            container = rhs_name
        }
        if container != "" {
            if dispatched, found := try_dispatch_binary(tc, env, v, op_str, container, lhs, rhs); found {
                return dispatched
            }
        }
    }

    switch v.op {
    case .Add, .Sub, .Mul, .Div, .Mod:
        if !ty_is_numeric(lhs) || !ty_is_numeric(rhs) {
            emit_error(tc, v.span, fmt.tprintf("arithmetic requires numeric operands, got %s and %s", ty_to_string(lhs), ty_to_string(rhs)))
            return ty_error()
        }
        return numeric_join(lhs, rhs)
    case .Eq, .Ne:
        if !ty_assignable(lhs, rhs) && !ty_assignable(rhs, lhs) {
            emit_error(tc, v.span, fmt.tprintf("cannot compare %s and %s", ty_to_string(lhs), ty_to_string(rhs)))
        }
        return ty_bool()
    case .Lt, .Gt, .Le, .Ge:
        if !ty_is_numeric(lhs) || !ty_is_numeric(rhs) {
            emit_error(tc, v.span, fmt.tprintf("ordering requires numeric operands, got %s and %s", ty_to_string(lhs), ty_to_string(rhs)))
        }
        return ty_bool()
    case .And, .Or:
        if !ty_is_bool(lhs) || !ty_is_bool(rhs) {
            emit_error(tc, v.span, fmt.tprintf("`&&` / `||` require bool operands, got %s and %s", ty_to_string(lhs), ty_to_string(rhs)))
        }
        return ty_bool()
    case .Range, .Range_Inclusive:
        if !ty_is_int(lhs) || !ty_is_int(rhs) {
            emit_error(tc, v.span, "ranges require integer bounds")
        }
        return numeric_join(lhs, rhs)
    }
    return ty_error()
}

operand_container_name :: proc(t: Ty) -> (string, bool) {
    if rec, ok := t.(^Ty_Record); ok do return rec.name, true
    if adt, ok := t.(^Ty_Adt);    ok do return adt.name, true
    if _, ok := t.(^Ty_String);   ok do return "string", true
    return "", false
}

operand_type_args :: proc(t: Ty) -> []Ty {
    if rec, ok := t.(^Ty_Record); ok do return rec.args
    if adt, ok := t.(^Ty_Adt);    ok do return adt.args
    return nil
}

try_dispatch_binary :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Binary, op: string, container: string, lhs_ty, rhs_ty: Ty) -> (Ty, bool) {
    key := Operator_Key{op = op, type_name = container}
    fn_name, found := tc.operator_table[key]
    if !found do return nil, false
    fn_decl, has := tc.fns[fn_name]
    if !has do return nil, false

    if len(fn_decl.params) != 2 {
        emit_error(tc, v.span, fmt.tprintf("`@operator(\"%s\")` function `%s` must take 2 parameters", op, fn_decl.name))
        return ty_error(), true
    }

    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }
    p0 := resolve_type(tc, fn_decl.params[0].type, &params_env)
    p1 := resolve_type(tc, fn_decl.params[1].type, &params_env)
    ret: Ty = ty_unit()
    if fn_decl.ret != nil do ret = resolve_type(tc, fn_decl.ret, &params_env)

    subst := make(map[int]Ty)
    ty_unify_var(p0, ty_ptr(lhs_ty), &subst)
    ty_unify_var(p1, ty_ptr(rhs_ty), &subst)

    instantiation := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }

    tc.binary_dispatches[v] = Index_Dispatch{fn_name = fn_decl.name, type_args = instantiation}
    return ty_substitute(ret, subst), true
}

try_dispatch_unary :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Unary, op: string, container: string) -> (Ty, bool) {
    key := Operator_Key{op = op, type_name = container}
    fn_name, found := tc.operator_table[key]
    if !found do return nil, false
    fn_decl, has := tc.fns[fn_name]
    if !has do return nil, false

    if len(fn_decl.params) != 1 {
        emit_error(tc, v.span, fmt.tprintf("`@operator(\"%s\")` function `%s` must take 1 parameter", op, fn_decl.name))
        return ty_error(), true
    }

    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }
    p0 := resolve_type(tc, fn_decl.params[0].type, &params_env)
    ret: Ty = ty_unit()
    if fn_decl.ret != nil do ret = resolve_type(tc, fn_decl.ret, &params_env)

    rhs_ty := synth(tc, env, v.rhs)
    subst := make(map[int]Ty)
    ty_unify_var(p0, ty_ptr(rhs_ty), &subst)

    instantiation := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }

    tc.unary_dispatches[v] = Index_Dispatch{fn_name = fn_decl.name, type_args = instantiation}
    return ty_substitute(ret, subst), true
}

numeric_join :: proc(a, b: Ty) -> Ty {
    a_untyped := false
    b_untyped := false
    if ai, ok := a.(^Ty_Int);   ok do a_untyped = ai.untyped
    if af, ok := a.(^Ty_Float); ok do a_untyped = af.untyped
    if bi, ok := b.(^Ty_Int);   ok do b_untyped = bi.untyped
    if bf, ok := b.(^Ty_Float); ok do b_untyped = bf.untyped
    if a_untyped && !b_untyped do return b
    if b_untyped && !a_untyped do return a
    return a
}

synth_assign :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Assign) -> Ty {
    if v.op == .Set {
        if idx, is_idx := v.target.(^Expr_Index); is_idx {
            base := synth(tc, env, idx.base)
            if container, ok := operand_container_name(base); ok {
                key := Operator_Key{op = "[]=", type_name = container}
                if fn_name, found := tc.operator_table[key]; found {
                    if fn_decl, has := tc.fns[fn_name]; has {
                        return dispatch_indexed_assign(tc, env, v, idx, fn_decl)
                    }
                }
            }
        }
    }
    target := synth(tc, env, v.target)
    check(tc, env, v.value, target)
    return ty_unit()
}

dispatch_indexed_assign :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Assign, idx: ^Expr_Index, fn_decl: ^Decl_Fn) -> Ty {
    if len(fn_decl.params) != 3 {
        emit_error(tc, v.span, fmt.tprintf("`@operator(\"[]=\")` function `%s` must take 3 parameters (collection, key, value)", fn_decl.name))
        return ty_error()
    }

    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }
    p0 := resolve_type(tc, fn_decl.params[0].type, &params_env)
    p1 := resolve_type(tc, fn_decl.params[1].type, &params_env)
    p2 := resolve_type(tc, fn_decl.params[2].type, &params_env)

    base_ty := synth(tc, env, idx.base)
    key_ty := synth(tc, env, idx.index)

    subst := make(map[int]Ty)
    ty_unify_var(p0, ty_ptr(base_ty), &subst)
    ty_unify_var(p1, key_ty, &subst)

    value_expected := ty_substitute(p2, subst)
    check(tc, env, v.value, value_expected)

    actual_value := tc.expr_types[v.value]
    if actual_value != nil do ty_unify_var(p2, actual_value, &subst)

    instantiation := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }

    tc.assign_dispatches[v] = Index_Dispatch{fn_name = fn_decl.name, type_args = instantiation}
    return ty_unit()
}

synth_call :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call) -> Ty {
    if path, is_path := v.callee.(^Expr_Path); is_path {
        if len(path.segs) == 2 && path.segs[0] == "fmt" && path.segs[1] == "println" {
            for a in v.args do synth(tc, env, a)
            return ty_unit()
        }
        if len(path.segs) == 2 {
            if enum_decl, ok := tc.enums[path.segs[0]]; ok {
                for i in 0..<len(enum_decl.variants) {
                    if enum_decl.variants[i].name == path.segs[1] {
                        return synth_variant_call(tc, env, v, enum_decl, &enum_decl.variants[i])
                    }
                }
                emit_error(tc, v.span, fmt.tprintf("`%s` has no variant `%s`", enum_decl.name, path.segs[1]))
                return ty_error()
            }
        }
        if len(path.segs) == 2 {
            if _, in_pkg := tc.packages[path.segs[0]]; in_pkg {
                qualified := fmt.tprintf("%s_%s", path.segs[0], path.segs[1])
                _, in_fns := tc.fns[qualified]
                _, in_externs := tc.externs[qualified]
                if in_fns || in_externs {
                    fake_id := new(Expr_Ident)
                    fake_id.span = path.span; fake_id.name = qualified
                    v.callee = fake_id
                    return synth_call(tc, env, v)
                }
                emit_error(tc, v.span, fmt.tprintf("package `%s` has no function `%s`", path.segs[0], path.segs[1]))
                return ty_error()
            }
        }
    }
    if id, is_id := v.callee.(^Expr_Ident); is_id {
        if is_unshadowed_builtin(tc, env, id.name) {
            switch id.name {
            case "println":
                for a in v.args do synth(tc, env, a)
                return ty_unit()
            case "size_of":
                if len(v.args) != 1 {
                    emit_error(tc, v.span, fmt.tprintf("size_of expects 1 type argument, got %d", len(v.args)))
                }
                return ty_int(64, true)
            case "hash":
                if len(v.args) != 1 {
                    emit_error(tc, v.span, fmt.tprintf("hash expects 1 argument, got %d", len(v.args)))
                }
                for a in v.args do synth(tc, env, a)
                return ty_int(64, false)
            case "len":
                if len(v.args) != 1 {
                    emit_error(tc, v.span, fmt.tprintf("len expects 1 argument, got %d", len(v.args)))
                }
                for a in v.args do synth(tc, env, a)
                return ty_int(64, true)
            }
        }
    }
    if id, is_id := v.callee.(^Expr_Ident); is_id {
        if _, in_env := env_lookup(env, id.name); !in_env {
            if vb, ok := variant_lookup_unique(tc, id.name); ok {
                tc.call_enum[v] = vb.enum_decl.name
                return synth_variant_call(tc, env, v, vb.enum_decl, vb.variant)
            }
        }
        if _, in_fns := tc.fns[id.name]; !in_fns {
            if _, in_externs := tc.externs[id.name]; !in_externs {
                if qualified, ok := resolve_pkg_short(tc, id.name); ok {
                    id.name = qualified
                }
            }
        }
        if fn_decl, ok := tc.fns[id.name]; ok && len(fn_decl.type_params) > 0 {
            return synth_generic_call(tc, env, v, fn_decl)
        }
    }
    callee_ty := synth(tc, env, v.callee)
    fn_ty, is_fn := callee_ty.(^Ty_Fn)
    if !is_fn {
        if !ty_is_error(callee_ty) {
            emit_error(tc, v.span, fmt.tprintf("call target is not a function: %s", ty_to_string(callee_ty)))
        }
        for a in v.args do synth(tc, env, a)
        return ty_error()
    }
    if len(v.args) != len(fn_ty.params) {
        emit_error(tc, v.span, fmt.tprintf("function expects %d argument(s), got %d", len(fn_ty.params), len(v.args)))
    }
    for a, i in v.args {
        if i < len(fn_ty.params) {
            check(tc, env, a, fn_ty.params[i])
        } else {
            synth(tc, env, a)
        }
    }
    return fn_ty.ret
}

// Instantiate a generic function at a call site. Fresh type variables stand
// in for each type parameter; argument types unify against the parameter
// types to discover concrete bindings; the substitution is applied to the
// return type and recorded for later monomorphisation.
synth_generic_call :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call, fn_decl: ^Decl_Fn) -> Ty {
    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }

    param_tys := make([]Ty, len(fn_decl.params))
    for p, i in fn_decl.params {
        param_tys[i] = resolve_type(tc, p.type, &params_env)
    }
    ret_ty: Ty = ty_unit()
    if fn_decl.ret != nil do ret_ty = resolve_type(tc, fn_decl.ret, &params_env)

    if len(v.args) != len(param_tys) {
        emit_error(tc, v.span, fmt.tprintf("function `%s` expects %d argument(s), got %d", fn_decl.name, len(param_tys), len(v.args)))
        for a in v.args do synth(tc, env, a)
        return ty_error()
    }

    subst := make(map[int]Ty)
    for arg, i in v.args {
        actual := synth(tc, env, arg)
        if !ty_unify_var(param_tys[i], actual, &subst) {
            substituted := ty_substitute(param_tys[i], subst)
            emit_error(tc, v.span, fmt.tprintf("argument %d: expected %s, got %s", i+1, ty_to_string(substituted), ty_to_string(actual)))
        }
    }

    instantiation := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`", fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }
    tc.call_instantiations[v] = instantiation

    return ty_substitute(ret_ty, subst)
}

// After generic inference, untyped numeric literals must collapse to a
// concrete default so codegen can emit a real C type. Matches the same rule
// applied to top-level `let` bindings without annotation.
synth_try :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Try) -> Ty {
    inner := synth(tc, env, v.value)
    inner_adt, ok := inner.(^Ty_Adt)
    if !ok || inner_adt.name != "Result" || len(inner_adt.args) != 2 {
        emit_error(tc, v.span, fmt.tprintf("`?` requires a Result<T, E> operand, got %s", ty_to_string(inner)))
        return ty_error()
    }
    outer := tc.current_fn_ret
    outer_adt, ok2 := outer.(^Ty_Adt)
    if !ok2 || outer_adt.name != "Result" || len(outer_adt.args) != 2 {
        emit_error(tc, v.span, fmt.tprintf("`?` is only allowed in a function returning Result<_, E>, found %s", ty_to_string(outer)))
        return ty_error()
    }
    if !ty_equal(inner_adt.args[1], outer_adt.args[1]) {
        emit_error(tc, v.span, fmt.tprintf("`?` operand error type %s does not match enclosing function's error type %s",
            ty_to_string(inner_adt.args[1]), ty_to_string(outer_adt.args[1])))
        return ty_error()
    }
    intern_adt(tc, "Result", outer_adt.args)
    intern_adt(tc, "Result", inner_adt.args)
    return inner_adt.args[0]
}

finalise_untyped :: proc(t: Ty) -> Ty {
    if ti, ok := t.(^Ty_Int);   ok && ti.untyped do return ty_int(64, true)
    if tf, ok := t.(^Ty_Float); ok && tf.untyped do return ty_float(64)
    return t
}

// Variant constructor calls of a generic ADT instantiate the enum's type
// parameters from argument types and intern the resulting concrete ADT type
// so codegen can emit a specialised struct for it.
synth_variant_call :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Call,
                            enum_decl: ^Decl_Enum, variant: ^Variant_Decl) -> Ty {
    if len(enum_decl.type_params) == 0 {
        param_tys: []Ty
        if variant.kind == .Positional {
            param_tys = make([]Ty, len(variant.pos))
            for t, i in variant.pos do param_tys[i] = resolve_type(tc, t)
        } else if variant.kind == .Named {
            param_tys = make([]Ty, len(variant.named))
            for fld, i in variant.named do param_tys[i] = resolve_type(tc, fld.type)
        }
        if len(v.args) != len(param_tys) {
            emit_error(tc, v.span, fmt.tprintf("`%s.%s` expects %d argument(s), got %d",
                enum_decl.name, variant.name, len(param_tys), len(v.args)))
        }
        for arg, i in v.args {
            if i < len(param_tys) {
                check(tc, env, arg, param_tys[i])
            } else {
                synth(tc, env, arg)
            }
        }
        return ty_adt(enum_decl.name, make([]Ty, 0))
    }

    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(enum_decl.type_params))
    for tp, i in enum_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }

    param_tys: []Ty
    if variant.kind == .Positional {
        param_tys = make([]Ty, len(variant.pos))
        for t, i in variant.pos do param_tys[i] = resolve_type(tc, t, &params_env)
    } else if variant.kind == .Named {
        param_tys = make([]Ty, len(variant.named))
        for fld, i in variant.named do param_tys[i] = resolve_type(tc, fld.type, &params_env)
    }

    if len(v.args) != len(param_tys) {
        emit_error(tc, v.span, fmt.tprintf("`%s.%s` expects %d argument(s), got %d",
            enum_decl.name, variant.name, len(param_tys), len(v.args)))
        for a in v.args do synth(tc, env, a)
        return ty_error()
    }

    subst := make(map[int]Ty)
    for arg, i in v.args {
        actual := synth(tc, env, arg)
        ty_unify_var(param_tys[i], actual, &subst)
    }

    type_args := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            type_args[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                enum_decl.type_params[i], enum_decl.name))
            type_args[i] = ty_error()
        }
    }

    tc.call_instantiations[v] = type_args
    intern_adt(tc, enum_decl.name, type_args)
    return ty_adt(enum_decl.name, type_args)
}

synth_field :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Field) -> Ty {
    base := synth(tc, env, v.base)
    return field_type_of(tc, base, v.name, v.span)
}

synth_record :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Record) -> Ty {
    if v.type == nil {
        emit_error(tc, v.span, "record literal needs an explicit type prefix in Stage A")
        return ty_error()
    }
    tn, ok := v.type^.(^Type_Named)
    if !ok || len(tn.path) != 1 {
        emit_error(tc, v.span, "record literal type must be a single named record")
        return ty_error()
    }
    name := tn.path[0]
    decl, found := tc.structs[name]
    if !found {
        emit_error(tc, v.span, fmt.tprintf("unknown record type `%s`", name))
        return ty_error()
    }

    params_env := make(map[string]Ty)
    tp_ptr: ^map[string]Ty = nil
    fresh_var_ids := make([]int, len(decl.type_params))
    use_inference := false
    if len(decl.type_params) > 0 {
        tp_ptr = &params_env
        if len(tn.args) == len(decl.type_params) {
            for tp, i in decl.type_params {
                params_env[tp] = resolve_type(tc, tn.args[i])
            }
        } else if len(tn.args) == 0 {
            use_inference = true
            for tp, i in decl.type_params {
                tv := fresh_ty_var(tc, tp)
                params_env[tp] = tv
                if t, ok2 := tv.(^Ty_Var); ok2 do fresh_var_ids[i] = t.id
            }
        } else {
            emit_error(tc, v.span, fmt.tprintf("record `%s` expects %d type argument(s), got %d", name, len(decl.type_params), len(tn.args)))
            return ty_error()
        }
    }

    field_types := make(map[string]Ty)
    for fld in decl.fields {
        field_types[fld.name] = resolve_type(tc, fld.type, tp_ptr)
    }

    subst := make(map[int]Ty)
    seen := make(map[string]bool)
    for fld in v.fields {
        expected, exists := field_types[fld.name]
        if !exists {
            emit_error(tc, v.span, fmt.tprintf("record `%s` has no field `%s`", name, fld.name))
            synth(tc, env, fld.value)
            continue
        }
        if use_inference {
            actual := synth(tc, env, fld.value)
            ty_unify_var(expected, actual, &subst)
        } else {
            check(tc, env, fld.value, expected)
        }
        seen[fld.name] = true
    }

    type_args := make([]Ty, len(decl.type_params))
    if use_inference {
        for id, i in fresh_var_ids {
            if mapped, ok2 := subst[id]; ok2 {
                mapped = finalise_untyped(mapped)
                subst[id] = mapped
                type_args[i] = mapped
            } else {
                emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`", decl.type_params[i], name))
                type_args[i] = ty_error()
            }
        }
    } else if len(decl.type_params) > 0 {
        for tp, i in decl.type_params {
            type_args[i] = params_env[tp]
        }
    }

    result := ty_record(name, type_args)
    if v.base != nil {
        base_ty := synth(tc, env, v.base)
        if !ty_assignable(base_ty, result) {
            emit_error(tc, v.span, fmt.tprintf("partial update base must be %s, got %s", ty_to_string(result), ty_to_string(base_ty)))
        }
    } else {
        for fld in decl.fields {
            if !seen[fld.name] {
                emit_error(tc, v.span, fmt.tprintf("missing field `%s` in record literal `%s`", fld.name, name))
            }
        }
    }

    if len(type_args) > 0 do intern_record(tc, name, type_args)
    return result
}

synth_index :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Index) -> Ty {
    base := synth(tc, env, v.base)
    idx := synth(tc, env, v.index)
    if ptr, is_ptr := base.(^Ty_Ptr); is_ptr {
        if !ty_is_int(idx) && !ty_is_error(idx) {
            emit_error(tc, v.span, fmt.tprintf("index must be an integer, got %s", ty_to_string(idx)))
        }
        return ptr.inner
    }
    if ty_is_error(base) do return ty_error()

    type_name := ""
    type_args: []Ty
    if rec, is_rec := base.(^Ty_Record); is_rec {
        type_name = rec.name
        type_args = rec.args
    } else if adt, is_adt := base.(^Ty_Adt); is_adt {
        type_name = adt.name
        type_args = adt.args
    }
    if type_name == "" {
        emit_error(tc, v.span, fmt.tprintf("cannot index into %s", ty_to_string(base)))
        return ty_error()
    }

    key := Operator_Key{op = "[]", type_name = type_name}
    fn_name, found := tc.operator_table[key]
    if !found {
        emit_error(tc, v.span, fmt.tprintf("no `[]` operator defined for `%s`; register a function with `@operator(\"[]\")`", type_name))
        return ty_error()
    }
    fn_decl, has := tc.fns[fn_name]
    if !has {
        return ty_error()
    }

    return dispatch_indexer(tc, env, v, fn_decl, type_args, idx)
}

dispatch_indexer :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Index, fn_decl: ^Decl_Fn, base_type_args: []Ty, idx_ty: Ty) -> Ty {
    params_env := make(map[string]Ty)
    fresh_var_ids := make([]int, len(fn_decl.type_params))
    for tp, i in fn_decl.type_params {
        tv := fresh_ty_var(tc, tp)
        params_env[tp] = tv
        if t, ok := tv.(^Ty_Var); ok do fresh_var_ids[i] = t.id
    }

    if len(fn_decl.params) != 2 {
        emit_error(tc, v.span, fmt.tprintf("`%s` must take 2 parameters (collection, index)", fn_decl.name))
        return ty_error()
    }
    param0 := resolve_type(tc, fn_decl.params[0].type, &params_env)
    param1 := resolve_type(tc, fn_decl.params[1].type, &params_env)
    ret: Ty = ty_unit()
    if fn_decl.ret != nil do ret = resolve_type(tc, fn_decl.ret, &params_env)

    base_ptr_ty := ty_ptr(synth(tc, env, v.base))
    subst := make(map[int]Ty)
    ty_unify_var(param0, base_ptr_ty, &subst)
    ty_unify_var(param1, idx_ty, &subst)

    instantiation := make([]Ty, len(fresh_var_ids))
    for id, i in fresh_var_ids {
        if mapped, ok := subst[id]; ok {
            mapped = finalise_untyped(mapped)
            subst[id] = mapped
            instantiation[i] = mapped
        } else {
            emit_error(tc, v.span, fmt.tprintf("could not infer type parameter `%s` of `%s`",
                fn_decl.type_params[i], fn_decl.name))
            instantiation[i] = ty_error()
        }
    }

    tc.index_dispatches[v] = Index_Dispatch{fn_name = fn_decl.name, type_args = instantiation}
    return ty_substitute(ret, subst)
}

synth_closure :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Closure) -> Ty {
    params := make([dynamic]Ty)
    inner := env_make(env)
    for p in v.params {
        pt: Ty
        if p.type != nil {
            pt = resolve_type(tc, p.type)
        } else {
            pt = ty_int(64, true)
        }
        env_define(inner, p.name, pt)
        append(&params, pt)
    }
    ret: Ty
    if v.ret != nil {
        ret = resolve_type(tc, v.ret)
        check(tc, inner, v.body, ret)
    } else {
        ret = synth(tc, inner, v.body)
    }
    return ty_fn(params[:], ret)
}

synth_if :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_If) -> Ty {
    check(tc, env, v.cond, ty_bool())
    then_ty := synth(tc, env, v.then_b)
    if v.else_b == nil do return ty_unit()
    else_ty := synth(tc, env, v.else_b)
    if ty_assignable(then_ty, else_ty) do return else_ty
    if ty_assignable(else_ty, then_ty) do return then_ty
    emit_error(tc, v.span, fmt.tprintf("`if` branches have differing types: %s vs %s", ty_to_string(then_ty), ty_to_string(else_ty)))
    return ty_error()
}

synth_match :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Match) -> Ty {
    scrut := synth(tc, env, v.scrutinee)
    scrut_adt := scrut
    if ptr, is_ptr := scrut.(^Ty_Ptr); is_ptr do scrut_adt = ptr.inner
    adt, is_adt := scrut_adt.(^Ty_Adt)
    if !is_adt && !ty_is_error(scrut) {
        emit_error(tc, v.span, fmt.tprintf("match scrutinee must be an ADT, got %s", ty_to_string(scrut)))
        return ty_error()
    }
    arm_ty: Ty = nil
    for arm in v.arms {
        arm_env := env_make(env)
        if is_adt {
            check_pattern(tc, arm_env, arm.pat, adt)
        }
        if arm.guard != nil do check(tc, arm_env, arm.guard, ty_bool())
        t := synth(tc, arm_env, arm.body)
        if arm_ty == nil {
            arm_ty = t
        } else if !ty_assignable(t, arm_ty) && !ty_assignable(arm_ty, t) {
            emit_error(tc, v.span, fmt.tprintf("match arms have differing types: %s vs %s", ty_to_string(arm_ty), ty_to_string(t)))
        }
    }
    if is_adt do check_match_exhaustive(tc, v, adt)
    if arm_ty == nil do return ty_unit()
    return arm_ty
}

check_match :: proc(tc: ^Ty_Context, env: ^Ty_Env, v: ^Expr_Match, expected: Ty) {
    scrut := synth(tc, env, v.scrutinee)
    scrut_adt := scrut
    if ptr, is_ptr := scrut.(^Ty_Ptr); is_ptr do scrut_adt = ptr.inner
    adt, is_adt := scrut_adt.(^Ty_Adt)
    if !is_adt && !ty_is_error(scrut) {
        emit_error(tc, v.span, fmt.tprintf("match scrutinee must be an ADT, got %s", ty_to_string(scrut)))
        return
    }
    for arm in v.arms {
        arm_env := env_make(env)
        if is_adt {
            check_pattern(tc, arm_env, arm.pat, adt)
        }
        if arm.guard != nil do check(tc, arm_env, arm.guard, ty_bool())
        check(tc, arm_env, arm.body, expected)
    }
    if is_adt do check_match_exhaustive(tc, v, adt)
}

// Stage A exhaustiveness: top-level only. A wildcard or bind pattern covers
// every remaining variant. A guarded arm does not count toward coverage,
// since the guard may fail at runtime. Nested patterns inside variant
// payloads are not exhaustively checked yet.
check_match_exhaustive :: proc(tc: ^Ty_Context, m: ^Expr_Match, adt: ^Ty_Adt) {
    e_decl, ok := tc.enums[adt.name]
    if !ok do return

    covered := make(map[string]bool, context.temp_allocator)
    has_wildcard := false

    for arm in m.arms {
        if arm.guard != nil do continue
        switch p in arm.pat {
        case ^Pat_Wild:
            has_wildcard = true
        case ^Pat_Bind:
            has_wildcard = true
        case ^Pat_Variant:
            variant_name := p.path.segs[len(p.path.segs)-1]
            covered[variant_name] = true
        case ^Pat_Lit_Int, ^Pat_Lit_String, ^Pat_Lit_Bool,
             ^Pat_Tuple, ^Pat_Record:
        }
        if has_wildcard do return
    }

    missing := make([dynamic]string, context.temp_allocator)
    for v in e_decl.variants {
        if !covered[v.name] do append(&missing, v.name)
    }
    if len(missing) == 0 do return

    sb := strings.builder_make(context.temp_allocator)
    for name, i in missing {
        if i > 0 do strings.write_string(&sb, ", ")
        strings.write_string(&sb, adt.name)
        strings.write_string(&sb, ".")
        strings.write_string(&sb, name)
    }
    emit_error(tc, m.span, fmt.tprintf("non-exhaustive match: missing %s. Add an arm or use `| _ -> ...` as a catch-all.", strings.to_string(sb)))
}

check_pattern :: proc(tc: ^Ty_Context, env: ^Ty_Env, p: Pattern, adt: ^Ty_Adt) {
    switch v in p {
    case ^Pat_Wild:
    case ^Pat_Bind:
        env_define(env, v.name, adt)
    case ^Pat_Lit_Int, ^Pat_Lit_String, ^Pat_Lit_Bool:
    case ^Pat_Tuple:
                                                                 // tuples are not yet structurally checked in Stage A
    case ^Pat_Record:
    case ^Pat_Variant:
        check_variant_pattern(tc, env, v, adt)
    }
}

check_variant_pattern :: proc(tc: ^Ty_Context, env: ^Ty_Env, pat: ^Pat_Variant, adt: ^Ty_Adt) {
    variant_name := pat.path.segs[len(pat.path.segs)-1]
    if len(pat.path.segs) >= 2 {
        qualifier := pat.path.segs[0]
        if qualifier != adt.name {
            emit_error(tc, pat.span, fmt.tprintf("pattern type `%s` does not match scrutinee type `%s`", qualifier, adt.name))
            return
        }
    }
    enum_decl, ok := tc.enums[adt.name]
    if !ok do return

    type_params: map[string]Ty
    tp_ptr: ^map[string]Ty = nil
    if len(enum_decl.type_params) > 0 && len(adt.args) == len(enum_decl.type_params) {
        type_params = make(map[string]Ty)
        for tp, i in enum_decl.type_params {
            type_params[tp] = adt.args[i]
        }
        tp_ptr = &type_params
    }

    for variant in enum_decl.variants {
        if variant.name != variant_name do continue
        if variant.kind == .Positional {
            if len(pat.pos) != len(variant.pos) {
                emit_error(tc, pat.span, fmt.tprintf("pattern `%s.%s` expects %d field(s), got %d", adt.name, variant_name, len(variant.pos), len(pat.pos)))
            }
            for sub, i in pat.pos {
                if i >= len(variant.pos) do break
                field_ty := resolve_type(tc, variant.pos[i], tp_ptr)
                bind_pattern(tc, env, sub, field_ty)
            }
            return
        }
        if variant.kind == .Named {
            for nf in pat.named {
                found := false
                for fld in variant.named {
                    if fld.name == nf.name {
                        bind_pattern(tc, env, nf.pat, resolve_type(tc, fld.type, tp_ptr))
                        found = true
                        break
                    }
                }
                if !found {
                    emit_error(tc, pat.span, fmt.tprintf("unknown field `%s` in pattern", nf.name))
                }
            }
            return
        }
        return
    }
    emit_error(tc, pat.span, fmt.tprintf("`%s` has no variant `%s`", adt.name, variant_name))
}

bind_pattern :: proc(tc: ^Ty_Context, env: ^Ty_Env, p: Pattern, expected: Ty) {
    switch v in p {
    case ^Pat_Wild:
    case ^Pat_Bind:
        env_define(env, v.name, expected)
    case ^Pat_Lit_Int, ^Pat_Lit_String, ^Pat_Lit_Bool:
    case ^Pat_Tuple:
    case ^Pat_Record:
    case ^Pat_Variant:
        if adt, ok := expected.(^Ty_Adt); ok {
            check_variant_pattern(tc, env, v, adt)
        }
    }
}

emit_error :: proc(tc: ^Ty_Context, span: Span, message: string) {
    append(&tc.errors, Type_Error{span = span, message = message})
}
