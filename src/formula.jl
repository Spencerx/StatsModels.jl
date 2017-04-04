# Formulas for representing and working with linear-model-type expressions
# Original by Harlan D. Harris.  Later modifications by John Myles White,
# Douglas M. Bates, and other contributors.

## Formulas are written as expressions and parsed by the Julia parser.
## For example :(y ~ a + b + log(c))
## In Julia the & operator is used for an interaction.  What would be written
## in R as y ~ a + b + a:b is written :(y ~ a + b + a&b) in Julia.
## The equivalent R expression, y ~ a*b, is the same in Julia

## The lhs of a one-sided formula is 'nothing'
## The rhs of a formula can be 1

type Formula
    lhs::Union{Symbol, Expr, Void}
    rhs::Union{Symbol, Expr, Integer}
end

Base.:(==)(a::Formula, b::Formula) = a.lhs == b.lhs && a.rhs == b.rhs

macro formula(ex)
    if (ex.head === :macrocall && ex.args[1] === Symbol("@~")) || (ex.head === :call && ex.args[1] === :(~))
        length(ex.args) == 3 || error("malformed expression in formula")
        lhs = Base.Meta.quot(ex.args[2])
        rhs = Base.Meta.quot(ex.args[3])
    else
        error("expected formula separator ~, got $(ex.head)")
    end
    return Expr(:call, :Formula, lhs, rhs)
end

Base.show(io::IO, f::Formula) =
    print(io, string("Formula: ", f.lhs === nothing ? "" : f.lhs, " ~ ", f.rhs))


## Define Terms type that manages formula parsing and extension.

abstract AbstractTerm

type Term{H} <: AbstractTerm
    children::Vector{AbstractTerm}

    Term() = new(AbstractTerm[])
    Term(children::Vector) = add_children!(new(AbstractTerm[]), children)
end

type EvalTerm <: AbstractTerm
    name::Symbol
end

typealias InterceptTerm Union{Term{0}, Term{-1}, Term{1}}

## equality of Terms
Base.:(==){H}(a::Term{H}, b::Term{H}) = a.children == b.children
Base.hash{H}(t::Term{H}, h::UInt) = hash(t.children, hash(H, h))

Base.:(==)(a::EvalTerm, b::EvalTerm) = a.name == b.name
Base.hash(t::EvalTerm, h::UInt) = hash(t.name, h)

## display of terms
function Base.show{H}(io::IO, t::Term{H})
    print(io, string(H))
    if length(t.children) > 0
        print(io, "(")
        print(io, join(map(string, t.children), ", "))
        print(io, ")")
    end
end
## show ranef term:
Base.show(io::IO, t::Term{:|}) = print(io, "(", t.children[1], " | ", t.children[2], ")")

Base.show(io::IO, t::EvalTerm) = print(io, string(t.name))

## Converting to Term:
Base.convert(::Type{AbstractTerm}, x::Any) = term(x)
term(x::AbstractTerm) = x
term(x::Any) = Term(x)

## Symbols are converted to EvalTerms (leaf nodes)
term(s::Symbol) = EvalTerm(s)

## Integers to intercept terms
function Term(i::Integer)
    i in -1:1 || throw(ArgumentError("Can't construct term from Integer $i"))
    Term{i}()
end

## no-op constructor
Term{H}(t::Term{H}) = t

## convert from one head type to another
(::Type{Term{H}}){H}(t::AbstractTerm) = add_children!(Term{H}(), t, [])

## Expressions are recursively converted to Terms, depth-first, and then added
## as children.  Specific `add_children!` methods handle special cases like
## associative and distributive operators.
function Base.convert(::Type{Term}, ex::Expr)
    ex.head == :call || error("non-call expression detected: '$(ex.head)'")
    add_children!(Term{ex.args[1]}(), [term(a) for a in ex.args[2:end]])
end


## Adding children to a Term

## General strategy: add one at a time to allow for dispatching on special
## cases, but also keep track of the rest of the children being added because at
## least the distributive rule requires that context.
add_children!(t::AbstractTerm, new_children::Vector) =
    isempty(new_children) ?
    t :
    add_children!(t, new_children[1], new_children[2:end])

function add_children!(t::AbstractTerm, c::AbstractTerm, others::Vector)
    push!(t.children, c)
    add_children!(t, others)
end

## special cases:
## Associative rule
add_children!(t::Term{:+}, new_child::Term{:+}, others::Vector) =
    add_children!(t, cat(1, new_child.children, others))
add_children!(t::Term{:&}, new_child::Term{:&}, others::Vector) =
    add_children!(t, cat(1, new_child.children, others))

## Distributive property
## &(a..., +(b...), c...) -> +(&(a..., b_i, c...)_i...)
add_children!(t::Term{:&}, new_child::Term{:+}, others::Vector) =
    Term{:+}([add_children!(deepcopy(t), c, others) for c in new_child.children])

## Expansion of a*b -> a + b + a&b
expand_star(a::AbstractTerm,b::AbstractTerm) = Term{:+}([a, b, Term{:&}([a,b])])
add_children!(t::Term, new_child::Term{:*}, others::Vector) =
    add_children!(t, cat(1, reduce(expand_star, new_child.children), others))

## Handle - for intercept term -1, and throw error otherwise
add_children!(t::Term{:-}, children::Vector) =
    isa(children[2], Term{1}) ?
    Term{:+}([children[1], Term{-1}()]) :
    error("invalid subtraction of $(children[2]); subtraction only supported for -1")

## sorting term by the degree of its children: order is 1 for everything except
## interaction Term{:&} where order is number of children
degree(t::Term{:&}) = length(t.children)
degree(::AbstractTerm) = 1
degree(::InterceptTerm) = 0

function Base.sort!(t::Term)
    sort!(t.children, by=degree)
    return t
end

################################################################################
## This duplicates the functionality of the DataFrames.Terms type:

## extract evaluation terms: children of Term{:+} and Term{:&}, nothing for
## ranef Term{:|} and intercept terms, and Term itself for everything else.
evt(t::AbstractTerm) = []
evt(t::Term{:&}) = mapreduce(evt, vcat, [], t.children)
evt(t::Term{:+}) = mapreduce(evt, vcat, [], t.children)
evt(t::EvalTerm) = [t.name]

## whether a Term is for fixed effects or not
isfe(t::Term{:|}) = false
isfe(t::AbstractTerm) = true

type Terms
    terms::Vector
    eterms::Vector        # evaluation terms
    factors::Matrix{Bool} # maps terms to evaluation terms
    ## An eterms x terms matrix which is true for terms that need to be "promoted"
    ## to full rank in constructing a model matrx
    is_non_redundant::Matrix{Bool}
# order can probably be dropped.  It is vec(sum(factors, 1))
    order::Vector{Int}    # orders of rhs terms
    response::Bool        # indicator of a response, which is eterms[1] if present
    intercept::Bool       # is there an intercept column in the model matrix?
end

Base.:(==)(t1::Terms, t2::Terms) = all(getfield(t1, f)==getfield(t2, f) for f in fieldnames(t1))

function Terms(f::Formula)
    ## start by raising everything on the right-hand side by converting
    rhs = sort!(Term{:+}(term(f.rhs)))
    terms = filter(isfe, unique(rhs.children))

    ## detect intercept
    is_intercept = [isa(t, InterceptTerm) for t in terms]
    hasintercept = mapreduce(t -> isa(t, Term{1}),
                             &,
                             true, # default is to have intercept
                             terms[is_intercept])

    terms = terms[!is_intercept]
    degrees = map(degree, terms)
    
    evalterms = map(evt, terms)

    haslhs = f.lhs !== nothing
    if haslhs
        lhs = term(f.lhs)
        unshift!(evalterms, evt(lhs))
        unshift!(degrees, degree(lhs))
    end

    evalterm_sets = [Set(x) for x in evalterms]
    evalterms = unique(reduce(vcat, [], evalterms))
    
    factors = Int8[t in s for t in evalterms, s in evalterm_sets]
    non_redundants = falses(size(factors)) # initialize to false

    Terms(terms, evalterms, factors, non_redundants, degrees, haslhs, hasintercept)

end





"""
    Formula(t::Terms)

Reconstruct a Formula from Terms.
"""
function Formula(t::Terms)
    lhs = t.response ? t.eterms[1] : nothing
    rhs = Expr(:call,:+)
    if t.intercept
        push!(rhs.args,1)
    end
    append!(rhs.args,t.terms)
    Formula(lhs,rhs)
end

function Base.copy(f::Formula)
    lhs = isa(f.lhs, Symbol) ? f.lhs : copy(f.lhs)
    return Formula(lhs, copy(f.rhs))
end

"""
    dropterm(f::Formula, trm::Symbol)

Return a copy of `f` without the term `trm`.

# Examples
```jl
julia> dropterm(@formula(foo ~ 1 + bar + baz), :bar)
Formula: foo ~ 1 + baz

julia> dropterm(@formula(foo ~ 1 + bar + baz), 1)
Formula: foo ~ 0 + bar + baz
```
"""
dropterm(f::Formula, trm::Union{Number, Symbol, Expr}) = dropterm!(copy(f), trm)

function dropterm!(f::Formula, trm::Union{Number, Symbol, Expr})
    rhs = f.rhs
    if !(Meta.isexpr(rhs, :call) && rhs.args[1] == :+ && (tpos = findlast(rhs.args, trm)) > 0)
        throw(ArgumentError("$trm is not a summand of '$(f.rhs)'"))
    end
    if isa(trm, Number)
        if trm ≠ one(trm)
            throw(ArgumentError("Cannot drop $trm from a formula"))
        end
        rhs.args[tpos] = 0
    else
        deleteat!(rhs.args, [tpos])
    end
    return f
end
