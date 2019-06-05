include("sexpressions.jl")

using Core: SSAValue

# Call into lowering stage 1; syntax desugaring
function fl_expand_forms(ex)
    ccall(:jl_call_scm_on_ast_formonly, Any, (Cstring, Any, Any), "expand-forms", ex, Main)
end

# Make it easy to replace fl_expand_forms with a julia version in the future.
expand_forms = ex->fl_expand_forms(ex)

function lift_lowered_expr!(ex, nextids, valmap, lift_full)
    if ex isa SSAValue
        # Rename SSAValues into renumbered symbols
        return get!(valmap, ex) do
            newid = nextids[1]
            nextids[1] = newid+1
            Symbol("ssa$newid")
        end
    end
    if ex isa Symbol
        if ex == Symbol("#self#")
            return :_self_
        end
        # Rename gensyms
        name = string(ex)
        if startswith(name, "#")
            return get!(valmap, ex) do
                newid = nextids[2]
                nextids[2] = newid+1
                Symbol("gsym$newid")
            end
        end
    end
    if ex isa Expr
        filter!(e->!(e isa LineNumberNode), ex.args)
        if ex.head == :block && length(ex.args) == 1
            # Remove trivial blocks
            return lift_lowered_expr!(ex.args[1], nextids, valmap, lift_full)
        end
        map!(ex.args, ex.args) do e
            lift_lowered_expr!(e, nextids, valmap, lift_full)
        end
        if lift_full
            # Lift exotic Expr heads into standard julia syntax for ease in
            # writing test case expressions.
            if ex.head == :top || ex.head == :core
                # Special global refs renamed to look like modules
                newhead = ex.head == :top ? :Top : :Core
                return Expr(:(.), newhead, QuoteNode(ex.args[1]))
            elseif ex.head == :unnecessary
                # `unnecessary` marks expressions generated by lowering that
                # do not need to be evaluated if their value is unused.
                return Expr(:call, :maybe_unused, ex.args...)
            elseif ex.head == Symbol("scope-block")
                return Expr(:let, Expr(:block), ex.args[1])
            end
        end
    elseif ex isa Vector # Occasional case of lambdas
        map!(ex, ex) do e
            lift_lowered_expr!(e, nextids, valmap, lift_full)
        end
    end
    return ex
end

"""
Clean up an `Expr` into an equivalent form which can be easily entered by
hand

* Replacing `SSAValue(id)` with consecutively numbered symbols :ssa\$i
* Remove trivial blocks
"""
function lift_lowered_expr(ex; lift_full=false)
    valmap = Dict{Union{Symbol,SSAValue},Symbol}()
    lift_lowered_expr!(deepcopy(ex), ones(Int,2), valmap, lift_full)
end

function to_sexpr!(ex, nextids, valmap)
    if ex isa SSAValue
        # Rename SSAValues into renumbered symbols
        return get!(valmap, ex) do
            newid = nextids[1]
            nextids[1] = newid+1
            Symbol("ssa$newid")
        end
    elseif ex isa Symbol
        if ex == Symbol("#self#")
            return :_self_
        end
        # Rename gensyms
        name = string(ex)
        if startswith(name, "#")
            return get!(valmap, ex) do
                newid = nextids[2]
                nextids[2] = newid+1
                Symbol("gsym$newid")
            end
        end
    elseif ex isa Expr
        filter!(e->!(e isa LineNumberNode), ex.args)
        if ex.head == :block && length(ex.args) == 1
            # Remove trivial blocks
            return to_sexpr!(ex.args[1], nextids, valmap)
        end
        map!(ex.args, ex.args) do e
            to_sexpr!(e, nextids, valmap)
        end
        return [ex.head; ex.args]
    elseif ex isa QuoteNode
        return [:quote, ex.value]
    elseif ex isa Vector # Occasional case of lambdas
        map!(ex, ex) do e
            to_sexpr!(e, nextids, valmap)
        end
    end
    return ex
end

function to_sexpr(ex)
    valmap = Dict{Union{Symbol,SSAValue},Symbol}()
    to_sexpr!(deepcopy(ex), ones(Int,2), valmap)
end

"""
Very slight lowering of reference expressions to allow comparison with
desugared forms.

* Remove trivial blocks
* Translate psuedo-module expressions Top.x and Core.x to Expr(:top) and
  Expr(:core)
"""
function lower_ref_expr!(ex)
    if ex isa Expr
        filter!(e->!(e isa LineNumberNode), ex.args)
        map!(lower_ref_expr!, ex.args, ex.args)
        if ex.head == :block && length(ex.args) == 1
            # Remove trivial blocks
            return lower_ref_expr!(ex.args[1])
        end
        # Translate a selection of special expressions into the exotic Expr
        # heads used in lowered code.
        if ex.head == :(.) && length(ex.args) >= 1 && (ex.args[1] == :Top ||
                                                       ex.args[1] == :Core)
            if !(length(ex.args) == 2 && ex.args[2] isa QuoteNode)
                throw("Unexpected top/core expression $(sprint(dump, ex))")
            end
            return Expr(ex.args[1] == :Top ? :top : :core, ex.args[2].value)
        elseif ex.head == :call && length(ex.args) >= 1 && ex.args[1] == :maybe_unused
            return Expr(:unnecessary, ex.args[2:end]...)
        elseif ex.head == :let && isempty(ex.args[1].args)
            return Expr(Symbol("scope-block"), ex.args[2])
        end
    end
    return ex
end
lower_ref_expr(ex) = lower_ref_expr!(deepcopy(ex))


function diffdump(io::IOContext, ex1, ex2, n, prefix, indent)
    if ex1 == ex2
        isempty(prefix) || print(io, prefix)
        dump(io, ex1, n, indent)
    else
        if ex1 isa Expr && ex2 isa Expr && ex1.head == ex2.head && length(ex1.args) == length(ex2.args)
            isempty(prefix) || print(io, prefix)
            println(io, "Expr")
            println(io, indent, "  head: ", ex1.head)
            println(io, indent, "  args: Array{Any}(", size(ex1.args), ")")
            for i in 1:length(ex1.args)
                prefix = string(indent, "    ", i, ": ")
                diffdump(io, ex1.args[i], ex2.args[i], n - 1, prefix, string("    ", indent))
                i < length(ex1.args) && println(io)
            end
        else
            printstyled(io, string(prefix, sprint(dump, ex1, n, indent; context=io)), color=:red)
            println()
            printstyled(io, string(prefix, sprint(dump, ex2, n, indent; context=io)), color=:green)
        end
    end
end

"""
Display colored differences between two expressions `ex1` and `ex2` using the
`dump` format.
"""
function diffdump(ex1, ex2; maxdepth=20)
    mod = get(stdout, :module, Main)
    diffdump(IOContext(stdout, :limit => true, :module => mod), ex1, ex2, maxdepth, "", "")
    println(stdout)
end

# For interactive convenience in constructing test cases with flisp based lowering
desugar(ex; lift_full=true) = lift_lowered_expr(expand_forms(ex); lift_full=lift_full)

"""
    @desugar ex [kws...]

Convenience macro, equivalent to `desugar(:(ex), kws...)`.
"""
macro desugar(ex, kws...)
    quote
        desugar($(Expr(:quote, ex)); $(map(esc, kws)...))
    end
end

macro desugar_sx(ex)
    quote
        SExprs.deparse(to_sexpr($(Expr(:quote, ex))))
    end
end

"""
Test that syntax desugaring of `input` produces an expression equivalent to the
reference expression `ref`.
"""
macro test_desugar(input, ref)
    ex = quote
        input = lift_lowered_expr(expand_forms($(Expr(:quote, input))))
        ref   = lower_ref_expr($(Expr(:quote, ref)))
        @test input == ref
        if input != ref
            # Kinda crude. Would be much neater if Test supported custom/more
            # capable diffing for failed tests.
            println("Diff dump:")
            diffdump(input, ref)
        end
    end
    # Attribute the test to the correct line number
    @assert ex.args[6].args[1] == Symbol("@test")
    ex.args[6].args[2] = __source__
    ex
end

macro test_desugar_sexpr(input, ref)
    ex = quote
        input = to_sexpr(expand_forms($(Expr(:quote, input))))
        ref   = SExprs.parse($(esc(ref)))
        @test input == ref
        if input != ref
            # Kinda crude. Would be much neater if Test supported custom/more
            # capable diffing for failed tests.
            println("Diff dump:")
            println(SExprs.deparse(input))
            println(SExprs.deparse(ref))
        end
    end
    # Attribute the test to the correct line number
    @assert ex.args[6].args[1] == Symbol("@test")
    ex.args[6].args[2] = __source__
    ex
end

macro test_desugar_error(input, msg)
    ex = quote
        input = lift_lowered_expr(expand_forms($(Expr(:quote, input))))
        @test input == Expr(:error, $msg)
    end
    # Attribute the test to the correct line number
    @assert ex.args[4].args[1] == Symbol("@test")
    ex.args[4].args[2] = __source__
    ex
end

#-------------------------------------------------------------------------------
# Tests

@testset "Property notation" begin
    # flisp: (expand-fuse-broadcast)
    @test_desugar a.b    Top.getproperty(a, :b)
    @test_desugar a.b.c  Top.getproperty(Top.getproperty(a, :b), :c)

    @test_desugar(a.b = c,
        begin
            Top.setproperty!(a, :b, c)
            maybe_unused(c)
        end
    )
    @test_desugar(a.b.c = d,
        begin
            ssa1 = Top.getproperty(a, :b)
            Top.setproperty!(ssa1, :c, d)
            maybe_unused(d)
        end
    )
end

# Example S-Expression version of the above.
@testset "Property notation" begin
    # flisp: (expand-fuse-broadcast)
    @test_desugar_sexpr a.b    "(call (top getproperty) a (quote b))"
    @test_desugar_sexpr a.b.c  "(call (top getproperty)
                                  (call (top getproperty) a (quote b))
                                  (quote c))"

    @test_desugar_sexpr(a.b = c,
        "(block
           (call (top setproperty!) a (quote b) c)
           (unnecessary c))"
    )
    @test_desugar_sexpr(a.b.c = d,
        "(block
           (= ssa1 (call (top getproperty) a (quote b)))
           (call (top setproperty!) ssa1 (quote c) d)
           (unnecessary d))"
    )
end


@testset "Index notation" begin
    # flisp: (process-indices) (partially-expand-ref)
    @testset "getindex" begin
        # Indexing
        @test_desugar a[i]      Top.getindex(a, i)
        @test_desugar a[i,j]    Top.getindex(a, i, j)
        # Indexing with `end`
        @test_desugar a[end]    Top.getindex(a, Top.lastindex(a))
        @test_desugar a[i,end]  Top.getindex(a, i, Top.lastindex(a,2))
        # Nesting of `end`
        @test_desugar a[[end]]  Top.getindex(a, Top.vect(Top.lastindex(a)))
        @test_desugar a[b[end] + end]  Top.getindex(a, Top.getindex(b, Top.lastindex(b)) + Top.lastindex(a))
        @test_desugar a[f(end) + 1]    Top.getindex(a, f(Top.lastindex(a)) + 1)
        # Interaction of `end` with splatting
        @test_desugar(a[I..., end],
            Core._apply(Top.getindex, Core.tuple(a), I,
                        Core.tuple(Top.lastindex(a, Top.:+(1, Top.length(I)))))
        )

        @test_desugar_error a[i,j;k]  "unexpected semicolon in array expression"
    end

    @testset "setindex!" begin
        # flisp: (lambda in expand-table)
        @test_desugar(a[i] = b,
            begin
                Top.setindex!(a, b, i)
                maybe_unused(b)
            end
        )
        @test_desugar(a[i,end] = b+c,
            begin
                ssa1 = b+c
                Top.setindex!(a, ssa1, i, Top.lastindex(a,2))
                maybe_unused(ssa1)
            end
        )
    end
end

@testset "Array notation" begin
    @testset "Literals" begin
        @test_desugar [a,b]     Top.vect(a,b)
        @test_desugar T[a,b]    Top.getindex(T, a,b)  # Only so much syntax to go round :-/
        @test_desugar_error [a,b;c]  "unexpected semicolon in array expression"
        @test_desugar_error [a=b,c]  "misplaced assignment statement in \"[a = b, c]\""
    end

    @testset "Concatenation" begin
        # flisp: (lambda in expand-table)
        @test_desugar [a b]     Top.hcat(a,b)
        @test_desugar [a; b]    Top.vcat(a,b)
        @test_desugar T[a b]    Top.typed_hcat(T, a,b)
        @test_desugar T[a; b]   Top.typed_vcat(T, a,b)
        @test_desugar [a b; c]  Top.hvcat(Core.tuple(2,1), a, b, c)
        @test_desugar T[a b; c] Top.typed_hvcat(T, Core.tuple(2,1), a, b, c)

        @test_desugar_error [a b=c]   "misplaced assignment statement in \"[a b = c]\""
        @test_desugar_error [a; b=c]  "misplaced assignment statement in \"[a; b = c]\""
        @test_desugar_error T[a b=c]  "misplaced assignment statement in \"T[a b = c]\""
        @test_desugar_error T[a; b=c] "misplaced assignment statement in \"T[a; b = c]\""
    end
end

@testset "Tuples" begin
    @test_desugar (x,y)      Core.tuple(x,y)
    @test_desugar (x=a,y=b)  Core.apply_type(Core.NamedTuple, Core.tuple(:x, :y))(Core.tuple(a, b))
end

@testset "Splatting" begin
    @test_desugar f(i,j,v...,k)  Core._apply(f, Core.tuple(i,j), v, Core.tuple(k))
end

@testset "Comparison chains" begin
    # flisp: (expand-compare-chain)
    @test_desugar(a < b < c,
        if a < b
            b < c
        else
            false
        end
    )
    # Nested
    @test_desugar(a < b > d <= e,
        if a < b
            if b > d
                d <= e
            else
                false
            end
        else
            false
        end
    )
    # Subexpressions
    @test_desugar(a < b+c < d,
        if (ssa1 = b+c; a < ssa1)
            ssa1 < d
        else
            false
        end
    )

    # Interaction with broadcast syntax
    @test_desugar(a < b .< c,
        Top.materialize(Top.broadcasted(&, a < b, Top.broadcasted(<, b, c)))
    )
    @test_desugar(a .< b+c < d,
        Top.materialize(Top.broadcasted(&,
                                        begin
                                            ssa1 = b+c
                                            # Is this a bug?
                                            Top.materialize(Top.broadcasted(<, a, ssa1))
                                        end,
                                        ssa1 < d))
    )
    @test_desugar(a < b+c .< d,
        Top.materialize(Top.broadcasted(&,
                                        begin
                                            ssa1 = b+c
                                            a < ssa1
                                        end,
                                        Top.broadcasted(<, ssa1, d)))
    )
end

@testset "Short circuit , ternary" begin
    # flisp: (expand-or) (expand-and)
    @test_desugar a || b      if a; a else b end
    @test_desugar a && b      if a; b else false end
    @test_desugar a ? x : y   if a; x else y end
end

@testset "Misc operators" begin
    @test_desugar a'    Top.adjoint(a)
    # <: and >: are special Expr heads which need to be turned into Expr(:call)
    # when used as operators
    @test_desugar a <: b  $(Expr(:call, :(<:), :a, :b))
    @test_desugar a >: b  $(Expr(:call, :(>:), :a, :b))
end

@testset "Broadcast" begin
    # Basic
    @test_desugar x .+ y        Top.materialize(Top.broadcasted(+, x, y))
    @test_desugar f.(x)         Top.materialize(Top.broadcasted(f, x))
    # Fusing
    @test_desugar f.(x) .+ g.(y)  Top.materialize(Top.broadcasted(+, Top.broadcasted(f, x),
                                                                  Top.broadcasted(g, y)))
    # Keywords don't participate
    @test_desugar(f.(x, a=1),
        Top.materialize(
            begin
                ssa1 = Top.broadcasted_kwsyntax
                ssa2 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
                Core.kwfunc(ssa1)(ssa2, ssa1, f, x)
            end
        )
    )
    # Nesting
    @test_desugar f.(g(x))      Top.materialize(Top.broadcasted(f, g(x)))
    @test_desugar f.(g(h.(x)))  Top.materialize(Top.broadcasted(f,
                                    g(Top.materialize(Top.broadcasted(h, x)))))

    # In place
    @test_desugar x .= a        Top.materialize!(x, Top.broadcasted(Top.identity, a))
    @test_desugar x .= f.(a)    Top.materialize!(x, Top.broadcasted(f, a))
    @test_desugar x .+= a       Top.materialize!(x, Top.broadcasted(+, x, a))
end

@testset "Keyword arguments" begin
    @test_desugar(
        f(x,a=1),
        begin
            ssa1 = Core.apply_type(Core.NamedTuple, Core.tuple(:a))(Core.tuple(1))
            Core.kwfunc(f)(ssa1, f, x)
        end
    )
end

@testset "In place update operators" begin
    # flisp: (lower-update-op)
    @test_desugar x += a       x = x+a
    @test_desugar x::Int += a  x = x::Int + a
    @test_desugar(x[end] += a,
        begin
            ssa1 = Top.lastindex(x)
            begin
                ssa2 = Top.getindex(x, ssa1) + a
                Top.setindex!(x, ssa2, ssa1)
                maybe_unused(ssa2)
            end
        end
    )
    @test_desugar(x[f(y)] += a,
        begin
            ssa1 = f(y)
            begin
                ssa2 = Top.getindex(x, ssa1) + a
                Top.setindex!(x, ssa2, ssa1)
                maybe_unused(ssa2)
            end
        end
    )
    @test_desugar((x,y) .+= a,
        begin
            ssa1 = Core.tuple(x, y)
            Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
        end
    )
    @test_desugar([x y] .+= a,
        begin
            ssa1 = Top.hcat(x, y)
            Top.materialize!(ssa1, Top.broadcasted(+, ssa1, a))
        end
    )
    @test_desugar_error (x+y) += 1  "invalid assignment location \"(x + y)\""
end

@testset "Assignment" begin
    # flisp: (lambda in expand-table)

    # Assignment chain; nontrivial rhs
    @test_desugar(x = y = f(a),
        begin
            ssa1 = f(a)
            y = ssa1
            x = ssa1
            maybe_unused(ssa1)
        end
    )

    @testset "Multiple Assignemnt" begin
        # Simple multiple assignment exact match
        @test_desugar((x,y) = (a,b),
            begin
                x = a
                y = b
                maybe_unused(Core.tuple(a,b))
            end
        )
        # Destructuring
        @test_desugar((x,y) = a,
            begin
                begin
                    ssa1 = Top.indexed_iterate(a, 1)
                    x = Core.getfield(ssa1, 1)
                    gsym1 = Core.getfield(ssa1, 2)
                    ssa1
                end
                begin
                    ssa2 = Top.indexed_iterate(a, 2, gsym1)
                    y = Core.getfield(ssa2, 1)
                    ssa2
                end
                maybe_unused(a)
            end
        )
        # Nested destructuring
        @test_desugar((x,(y,z)) = a,
            begin
                begin
                    ssa1 = Top.indexed_iterate(a, 1)
                    x = Core.getfield(ssa1, 1)
                    gsym1 = Core.getfield(ssa1, 2)
                    ssa1
                end
                begin
                    ssa2 = Top.indexed_iterate(a, 2, gsym1)
                    begin
                        ssa3 = Core.getfield(ssa2, 1)
                        begin
                            ssa4 = Top.indexed_iterate(ssa3, 1)
                            y = Core.getfield(ssa4, 1)
                            gsym2 = Core.getfield(ssa4, 2)
                            ssa4
                        end
                        begin
                            ssa5 = Top.indexed_iterate(ssa3, 2, gsym2)
                            z = Core.getfield(ssa5, 1)
                            ssa5
                        end
                        maybe_unused(ssa3)
                    end
                    ssa2
                end
                maybe_unused(a)
            end
        )
    end

    # Invalid assignments
    @test_desugar_error 1=a      "invalid assignment location \"1\""
    @test_desugar_error true=a   "invalid assignment location \"true\""
    @test_desugar_error "str"=a  "invalid assignment location \"\"str\"\""
    @test_desugar_error [x y]=c  "invalid assignment location \"[x y]\""
    @test_desugar_error a[x y]=c "invalid spacing in left side of indexed assignment"
    @test_desugar_error a[x;y]=c "unexpected \";\" in left side of indexed assignment"
    @test_desugar_error [x;y]=c  "use \"(a, b) = ...\" to assign multiple values"

    # Old deprecation (6575e12ba46)
    @test_desugar_error x.(y)=c  "invalid syntax \"x.(y) = ...\""
end

@testset "Declarations" begin
    # flisp: (expand-decls) (expand-local-or-global-decl) (expand-const-decl)

    # const
    @test_desugar((const x=a),
        begin
            $(Expr(:const, :x)) # `const x` is invalid surface syntax
            x = a
        end
    )
    @test_desugar((const x,y = a,b),
        begin
            $(Expr(:const, :x))
            $(Expr(:const, :y))
            begin
                x = a
                y = b
                maybe_unused(Core.tuple(a,b))
            end
        end
    )

    # local
    @test_desugar((local x, y),
        begin
            local y
            local x
        end
    )
    # Locals with initialization. Note parentheses are needed for this to parse
    # as individual assignments rather than multiple assignment.
    @test_desugar((local (x=a), (y=b), z),
        begin
            local z
            local y
            local x
            x = a
            y = b
        end
    )
    # Multiple assignment form
    @test_desugar(begin
                      local x,y = a,b
                  end,
        begin
            local x
            local y
            begin
                x = a
                y = b
                maybe_unused(Core.tuple(a,b))
            end
        end
    )

    # global
    @test_desugar((global x, (y=a)),
        begin
            global y
            global x
            y = a
        end
    )

    # type decl
    @test_desugar(x::T = a,
        begin
            $(Expr(:decl, :x, :T))
            x = a
        end
    )

    # type aliases
    @test_desugar(A{T} = B{T},
        begin
            $(Expr(Symbol("const-if-global"), :A))
            A = let
                $(Expr(Symbol("local-def"), :T))
                T = Core.TypeVar(:T)
                Core.UnionAll(T, Core.apply_type(B, T))
            end
        end
    )

end

@testset "let blocks" begin
    # flisp: (expand-let)
    @test_desugar(let x,y
                      body
                  end,
        begin
            let
                local x
                let
                    local y
                    body
                end
            end
        end
    )
    # Let with assignment
    @test_desugar(let x=a,y=b
                      body
                  end,
        begin
            let
                $(Expr(Symbol("local-def"), :x))
                x = a
                let
                    $(Expr(Symbol("local-def"), :y))
                    y = b
                    body
                end
            end
        end
    )
    # TODO: More coverage. Internals look complex.
end

@testset "Loops" begin
    # flisp: (expand-for) (lambda in expand-forms)
    @test_desugar(while cond
                      body1
                      continue
                      body2
                      break
                      body3
                  end,
        $(Expr(Symbol("break-block"), Symbol("loop-exit"),
               Expr(:_while, :cond,
                    Expr(Symbol("break-block"), Symbol("loop-cont"),
                         :(let
                             body1
                             $(Expr(:break, Symbol("loop-cont")))
                             body2
                             $(Expr(:break, Symbol("loop-exit")))
                             body3
                         end)))))
    )

    # Alternative with S-Expressions
    @test_desugar_sexpr(while cond
                            body1
                            continue
                            body2
                            break
                            body3
                        end,
        "(break-block loop-exit
           (_while cond
             (break-block loop-cont
               (scope-block
                 (block
                    body1
                    (break loop-cont)
                    body2
                    (break loop-exit)
                    body3)))))"
    )

    @test_desugar(for i = a
                      body1
                      continue
                      body2
                      break
                  end,
        $(Expr(Symbol("break-block"), Symbol("loop-exit"),
               quote
                   ssa1 = a
                   gsym1 = Top.iterate(ssa1)
                   if Top.not_int(Core.:(===)(gsym1, $nothing))
                       $(Expr(:_do_while,
                              quote
                                  $(Expr(Symbol("break-block"), Symbol("loop-cont"),
                                         :(let
                                             local i
                                             begin
                                                 ssa2 = gsym1
                                                 i = Core.getfield(ssa2, 1)
                                                 ssa3 = Core.getfield(ssa2, 2)
                                                 ssa2
                                             end
                                             begin
                                                 body1
                                                 $(Expr(:break, Symbol("loop-cont")))
                                                 body2
                                                 $(Expr(:break, Symbol("loop-exit")))
                                             end
                                         end)))
                                  gsym1 = Top.iterate(ssa1, ssa3)
                              end,
                              :(Top.not_int(Core.:(===)(gsym1, $nothing)))))
                   end
               end))
    )

    # For loops with `outer`
    @test_desugar(for outer i = a
                      body
                  end,
        $(Expr(Symbol("break-block"), Symbol("loop-exit"),
               quote
                   ssa1 = a
                   gsym1 = Top.iterate(ssa1)
                   $(Expr(Symbol("require-existing-local"), :i))  # Cf above.
                   if Top.not_int(Core.:(===)(gsym1, $nothing))
                       $(Expr(:_do_while,
                              quote
                                  $(Expr(Symbol("break-block"), Symbol("loop-cont"),
                                         :(let
                                             begin
                                                 ssa2 = gsym1
                                                 i = Core.getfield(ssa2, 1)
                                                 ssa3 = Core.getfield(ssa2, 2)
                                                 ssa2
                                             end
                                             begin
                                                 body
                                             end
                                         end)))
                                  gsym1 = Top.iterate(ssa1, ssa3)
                              end,
                              :(Top.not_int(Core.:(===)(gsym1, $nothing)))))
                   end
               end))
    )
end

@testset "Functions" begin
    # Short form
    @test_desugar(f(x) = body(x),
        begin
            $(Expr(:method, :f))
            $(Expr(:method, :f,
                   :(Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec())),
                   Expr(:lambda, [:_self_, :x], [],
                        :(let
                              body(x)
                          end))))
            maybe_unused(f)
        end
    )

    # Long form with argument annotations
    @test_desugar(function f(x::T, y)
                      body(x)
                  end,
        begin
            $(Expr(:method, :f))
            $(Expr(:method, :f,
                   :(Core.svec(Core.svec(Core.Typeof(f), T, Core.Any), Core.svec())),
                   Expr(:lambda, [:_self_, :x, :y], [],
                        :(let
                              body(x)
                          end))))
            maybe_unused(f)
        end
    )

    # Default arguments
    @test_desugar(function f(x=a, y=b)
                      body(x,y)
                  end,
        begin
            begin
                $(Expr(:method, :f))
                $(Expr(:method, :f,
                       :(Core.svec(Core.svec(Core.Typeof(f)), Core.svec())),
                       Expr(:lambda, [:_self_], [],
                            :(let
                                  _self_(a, b)
                              end))))
                maybe_unused(f)
            end
            begin
                $(Expr(:method, :f))
                $(Expr(:method, :f,
                       :(Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec())),
                       Expr(:lambda, [:_self_, :x], [],
                            :(let
                                  _self_(x, b)
                              end))))
                maybe_unused(f)
            end
            begin
                $(Expr(:method, :f))
                $(Expr(:method, :f,
                       :(Core.svec(Core.svec(Core.Typeof(f), Core.Any, Core.Any), Core.svec())),
                       Expr(:lambda, [:_self_, :x, :y], [],
                            :(let
                                  body(x,y)
                              end))))
                maybe_unused(f)
            end
        end
    )

    # Varargs
    @test_desugar(function f(x, args...)
                      body(x, args)
                  end,
        begin
            $(Expr(:method, :f))
            $(Expr(:method, :f,
                   :(Core.svec(Core.svec(Core.Typeof(f), Core.Any, Core.apply_type(Vararg, Core.Any)), Core.svec())),
                   Expr(:lambda, [:_self_, :x, :args], [],
                        :(let
                              body(x, args)
                          end))))
            maybe_unused(f)
        end
    )

    # Keyword arguments
    @test_desugar(function f(x; k1=v1, k2=v2)
                      body
                  end,
        begin
            Core.ifelse(false, false,
            begin
              $(Expr(:method, :f))
              begin
                  $(Expr(:method, :gsym1))
                  $(Expr(:method, :gsym1,
                         :(Core.svec(Core.svec(Core.typeof(gsym1), Core.Any, Core.Any, Core.Typeof(f), Core.Any), Core.svec())),
                         Expr(:lambda, [:gsym1, :k1, :k2, :_self_, :x], [],
                              :(let
                                    body
                                end))))
                  maybe_unused(gsym1)
              end
              begin
                  $(Expr(:method, :f))
                  $(Expr(:method, :f,
                         :(Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec())),
                         Expr(:lambda, [:_self_, :x], [],
                              :(let
                                   return gsym1(v1, v2, _self_, x)
                               end))))
                  maybe_unused(f)
              end
              begin
                  $(Expr(:method, :f))
                  $(Expr(:method, :f,
                         :(Core.svec(Core.svec(Core.kwftype(Core.Typeof(f)), Core.Any, Core.Typeof(f), Core.Any), Core.svec())),
                         Expr(:lambda, [:gsym2, :gsym3, :_self_, :x], [],
                              :(let
                                    let
                                        $(Expr(Symbol("local-def"), :k1))
                                        k1 = if Top.haskey(gsym3, :k1)
                                            Top.getindex(gsym3, :k1)
                                        else
                                            v1
                                        end
                                        let
                                            $(Expr(Symbol("local-def"), :k2))
                                            k2 = if Top.haskey(gsym3, :k2)
                                                Top.getindex(gsym3, :k2)
                                            else
                                                v2
                                            end
                                            begin
                                                ssa1 = Top.pairs(Top.structdiff(gsym3, Core.apply_type(Core.NamedTuple, Core.tuple(:k1, :k2))))
                                                if Top.isempty(ssa1)
                                                    $nothing
                                                else
                                                    Top.kwerr(gsym3, _self_, x)
                                                end
                                                return gsym1(k1, k2, _self_, x)
                                            end
                                        end
                                    end
                                end))))
                  maybe_unused(f)
              end
              f
          end)
        end
    )

    # Return type declaration
    @test_desugar(function f(x)::T
                      body(x)
                  end,
        begin
            $(Expr(:method, :f))
            $(Expr(:method, :f,
                   :(Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec())),
                   Expr(:lambda, [:_self_, :x], [],
                        :(let
                            ssa1 = T
                            $(Expr(:meta, Symbol("ret-type"), :ssa1))
                            body(x)
                        end))))
            maybe_unused(f)
        end
    )

    # Anon functions
    @test_desugar((x,y)->body(x,y),
        begin
            local gsym1
            begin
                $(Expr(:method, :gsym1))
                $(Expr(:method, :gsym1,
                       :(Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any, Core.Any), Core.svec())),
                       Expr(:lambda, [:_self_, :x, :y], [],
                            :(let
                                  body(x, y)
                              end))))
                maybe_unused(gsym1)
            end
        end
    )

    # Invalid names
    @test_desugar_error ccall(x)=body    "invalid function name \"ccall\""
    @test_desugar_error cglobal(x)=body  "invalid function name \"cglobal\""
    @test_desugar_error true(x)=body     "invalid function name \"true\""
    @test_desugar_error false(x)=body    "invalid function name \"false\""
end

@testset "Generated functions" begin
    ln = LineNumberNode(@__LINE__()+2, Symbol(@__FILE__))
    @test_desugar(function f(x)
                      body1(x)
                      if $(Expr(:generated))
                          gen_body1(x)
                      else
                          normal_body1(x)
                      end
                      body2
                      if $(Expr(:generated))
                          gen_body2
                      else
                          normal_body2
                      end
                  end,
        begin
            begin
                global gsym1
                begin
                    $(Expr(:method, :gsym1))
                    $(Expr(:method, :gsym1,
                           :(Core.svec(Core.svec(Core.Typeof(gsym1), Core.Any, Core.Any), Core.svec())),
                           Expr(:lambda, [:_self_, :gsym2, :x], [],
                                :(let
                                      $(Expr(:meta, :nospecialize, :gsym2, :x))
                                      Core._expr(:block,
                                                 $(QuoteNode(LineNumberNode(ln.line, ln.file))),
                                                 $(Expr(:copyast, QuoteNode(:(body1(x))))),
                                                 # FIXME: These line numbers seem buggy?
                                                 $(QuoteNode(LineNumberNode(ln.line+1, ln.file))),
                                                 gen_body1(x),
                                                 $(QuoteNode(LineNumberNode(ln.line+6, ln.file))),
                                                 :body2,
                                                 $(QuoteNode(LineNumberNode(ln.line+7, ln.file))),
                                                 gen_body2
                                                )
                                  end))))
                    maybe_unused(gsym1)
                end
            end
            $(Expr(:method, :f))
            $(Expr(:method, :f,
                   :(Core.svec(Core.svec(Core.Typeof(f), Core.Any), Core.svec())),
                   Expr(:lambda, [:_self_, :x], [],
                        :(let
                              $(Expr(:meta, :generated,
                                     Expr(:new, :(Core.GeneratedFunctionStub),
                                          :gsym1, [:_self_, :x],
                                          :nothing, ln.line,
                                          QuoteNode(ln.file), false)))
                              body1(x)
                              normal_body1(x)
                              body2
                              normal_body2
                          end))))
            maybe_unused(f)
        end
    )
end

@testset "Forms without desugaring" begin
    # (expand-forms)
    # The following Expr heads are currently not touched by desugaring
    for head in [:quote, :top, :core, :globalref, :outerref, :module, :toplevel, :null, :meta, :using, :import, :export]
        ex = Expr(head, Expr(:foobar, :junk, nothing, 42))
        @test expand_forms(ex) == ex
    end
    # flisp: inert,line have special representations on the julia side
    @test expand_forms(QuoteNode(Expr(:$, :x))) == QuoteNode(Expr(:$, :x)) # flisp: `(inert ,expr)
    @test expand_forms(LineNumberNode(1, :foo)) == LineNumberNode(1, :foo) # flisp: `(line ,line ,file)
end
