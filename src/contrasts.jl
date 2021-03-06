# Specify contrasts for coding categorical data in model matrix. Contrasts types
# are a subtype of AbstractContrasts. ContrastsMatrix types hold a contrast
# matrix, levels, and term names and provide the interface for creating model
# matrix columns and coefficient names.
#
# Contrasts types themselves can be instantiated to provide containers for
# contrast settings (currently, just the base level).
#
# ModelFrame will hold a Dict{Symbol, ContrastsMatrix} that maps column
# names to contrasts.
#
# ModelMatrix will check this dict when evaluating terms, falling back to a
# default for any categorical data without a specified contrast.


"""
Interface to describe contrast coding systems for categorical variables.

Concrete subtypes of `AbstractContrasts` describe a particular way of converting a
categorical data vector into numeric columns in a `ModelMatrix`. Each
instantiation optionally includes the levels to generate columns for and the base
level. If not specified these will be taken from the data when a `ContrastsMatrix` is
generated (during `ModelFrame` construction).

# Constructors

For `C <: AbstractContrast`:

```julia
C()                                     # levels are inferred later
C(levels = ::Vector{Any})               # levels checked against data later
C(base = ::Any)                         # specify base level
C(levels = ::Vector{Any}, base = ::Any) # specify levels and base
```

# Arguments

* `levels`: Optionally, the data levels can be specified here.  This allows you
  to specify the order of the levels.  If specified, the levels will be checked
  against the levels actually present in the data when the `ContrastsMatrix` is
  constructed. Any mismatch will result in an error, because levels missing in
  the data would lead to empty columns in the model matrix, and levels missing
  from the contrasts would lead to empty or undefined rows.
* `base`: The base level may also be specified.  The actual interpretation
  of this depends on the particular contrast type, but in general it can be
  thought of as a "reference" level.  It defaults to the first level.

# Contrast coding systems

* [`DummyCoding`](@ref) - Code each non-base level as a 0-1 indicator column.
* [`EffectsCoding`](@ref) - Code each non-base level as 1, and base as -1.
* [`HelmertCoding`](@ref) - Code each non-base level as the difference from the
  mean of the lower levels
* [`ContrastsCoding`](@ref) - Manually specify contrasts matrix

The last coding type, `ContrastsCoding`, provides a way to manually specify a
contrasts matrix. For a variable `x` with `k` levels, a contrasts matrix `M` is a
`k×k-1` matrix, that maps the `k` levels onto `k-1` model matrix columns.
Specifically, let `X` be the full-rank indicator matrix for `x`, where
`X[i,j] = 1` if `x[i] == levels(x)[j]`, and 0 otherwise. Then the model matrix
columns generated by the contrasts matrix `M` are `Y = X * M`.

# Extending

The easiest way to specify custom contrasts is with `ContrastsCoding`.  But if
you want to actually implement a custom contrast coding system, you can
subtype `AbstractContrasts`.  This requires a constructor, a
`contrasts_matrix` method for constructing the actual contrasts matrix that maps
from levels to `ModelMatrix` column values, and (optionally) a `termnames`
method:

```julia
mutable struct MyCoding <: AbstractContrasts
    ...
end

contrasts_matrix(C::MyCoding, baseind, n) = ...
termnames(C::MyCoding, levels, baseind) = ...
```

"""
abstract type AbstractContrasts end

# Contrasts + Levels (usually from data) = ContrastsMatrix
mutable struct ContrastsMatrix{C <: AbstractContrasts, T}
    matrix::Matrix{Float64}
    termnames::Vector{T}
    levels::Vector{T}
    contrasts::C
end

# only check equality of matrix, termnames, and levels, and that the type is the
# same for the contrasts (values are irrelevant).  This ensures that the two
# will behave identically in creating modelmatrix columns
Base.:(==)(a::ContrastsMatrix{C,T}, b::ContrastsMatrix{C,T}) where {C<:AbstractContrasts,T} =
    a.matrix == b.matrix &&
    a.termnames == b.termnames &&
    a.levels == b.levels

Base.hash(a::ContrastsMatrix{C}, h::UInt) where {C} =
    hash(C, hash(a.matrix, hash(a.termnames, hash(a.levels, h))))

"""
An instantiation of a contrast coding system for particular levels

This type is used internally for generating model matrices based on categorical
data, and **most users will not need to deal with it directly**.  Conceptually,
a `ContrastsMatrix` object stands for an instantiation of a contrast coding
*system* for a particular set of categorical *data levels*.

If levels are specified in the `AbstractContrasts`, those will be used, and likewise
for the base level (which defaults to the first level).

# Constructors

```julia
ContrastsMatrix(contrasts::AbstractContrasts, levels::AbstractVector)
ContrastsMatrix(contrasts_matrix::ContrastsMatrix, levels::AbstractVector)
```

# Arguments

* `contrasts::AbstractContrasts`: The contrast coding system to use.
* `levels::AbstractVector`: The levels to generate contrasts for.
* `contrasts_matrix::ContrastsMatrix`: Constructing a `ContrastsMatrix` from
  another will check that the levels match.  This is used, for example, in
  constructing a model matrix from a `ModelFrame` using different data.

"""
function ContrastsMatrix(contrasts::AbstractContrasts, levels::AbstractVector)

    # if levels are defined on contrasts, use those, validating that they line up.
    # what does that mean? either:
    #
    # 1. contrasts.levels == levels (best case)
    # 2. data levels missing from contrast: would generate empty/undefined rows.
    #    better to filter data frame first
    # 3. contrast levels missing from data: would have empty columns, generate a
    #    rank-deficient model matrix.
    c_levels = get(contrasts.levels, levels)
    if eltype(c_levels) != eltype(levels)
        throw(ArgumentError("mismatching levels types: got $(eltype(levels)), expected " *
                            "$(eltype(c_levels)) based on contrasts levels."))
    end
    mismatched_levels = symdiff(c_levels, levels)
    if !isempty(mismatched_levels)
        throw(ArgumentError("contrasts levels not found in data or vice-versa: " *
                            "$mismatched_levels." *
                            "\n  Data levels: $levels." *
                            "\n  Contrast levels: $c_levels"))
    end

    n = length(c_levels)
    if n == 0
        throw(ArgumentError("empty set of levels found (need at least two to compute " *
                            "contrasts)."))
    elseif n == 1
        throw(ArgumentError("only one level found: $(c_levels[1]) (need at least two to " *
                            "compute contrasts)."))
    end

    # find index of base level. use contrasts.base, then default (1).
    baseind = isnull(contrasts.base) ?
              1 :
              findfirst(equalto(get(contrasts.base)), c_levels)
    if baseind < 1
        throw(ArgumentError("base level $(get(contrasts.base)) not found in levels " *
                            "$c_levels."))
    end

    tnames = termnames(contrasts, c_levels, baseind)

    mat = contrasts_matrix(contrasts, baseind, n)

    ContrastsMatrix(mat, tnames, c_levels, contrasts)
end

ContrastsMatrix(c::Type{<:AbstractContrasts}, levels::AbstractVector) =
    throw(ArgumentError("contrast types must be instantiated (use $c() instead of $c)"))

# given an existing ContrastsMatrix, check that all passed levels are present
# in the contrasts. Note that this behavior is different from the
# ContrastsMatrix constructor, which requires that the levels be exactly the same.
# This method exists to support things like `predict` that can operate on new data
# which may contain only a subset of the original data's levels. Checking here
# (instead of in `modelmat_cols`) allows an informative error message.
function ContrastsMatrix(c::ContrastsMatrix, levels::AbstractVector)
    if !isempty(setdiff(levels, c.levels))
         throw(ArgumentError("there are levels in data that are not in ContrastsMatrix: " *
                             "$(setdiff(levels, c.levels))" *
                             "\n  Data levels: $(levels)" *
                             "\n  Contrast levels: $(c.levels)"))
    end
    return c
end

function termnames(C::AbstractContrasts, levels::AbstractVector, baseind::Integer)
    not_base = [1:(baseind-1); (baseind+1):length(levels)]
    levels[not_base]
end

nullify(x::Nullable) = x
nullify(x) = Nullable(x)

# Making a contrast type T only requires that there be a method for
# contrasts_matrix(T,  baseind, n) and optionally termnames(T, levels, baseind)
# The rest is boilerplate.
for contrastType in [:DummyCoding, :EffectsCoding, :HelmertCoding]
    @eval begin
        mutable struct $contrastType <: AbstractContrasts
            base::Nullable{Any}
            levels::Nullable{Vector}
        end
        ## constructor with optional keyword arguments, defaulting to Nullables
        $contrastType(;
                      base=Nullable{Any}(),
                      levels=Nullable{Vector}()) =
                          $contrastType(nullify(base),
                                        nullify(levels))
    end
end

"""
    FullDummyCoding()

Full-rank dummy coding generates one indicator (1 or 0) column for each level,
**including** the base level.

Not exported but included here for the sake of completeness.
Needed internally for some situations where a categorical variable with ``k``
levels needs to be converted into ``k`` model matrix columns instead of the
standard ``k-1``.  This occurs when there are missing lower-order terms, as in
discussed below in [Categorical variables in Formulas](@ref).

# Examples

```julia
julia> StatsModels.ContrastsMatrix(StatsModels.FullDummyCoding(), ["a", "b", "c", "d"]).matrix
4×4 Array{Float64,2}:
 1.0  0.0  0.0  0.0
 0.0  1.0  0.0  0.0
 0.0  0.0  1.0  0.0
 0.0  0.0  0.0  1.0
```
"""
mutable struct FullDummyCoding <: AbstractContrasts
# Dummy contrasts have no base level (since all levels produce a column)
end

ContrastsMatrix(C::FullDummyCoding, levels::AbstractVector) =
    ContrastsMatrix(eye(Float64, length(levels)), levels, levels, C)

"Promote contrasts matrix to full rank version"
Base.convert(::Type{ContrastsMatrix{FullDummyCoding}}, C::ContrastsMatrix) =
    ContrastsMatrix(FullDummyCoding(), C.levels)

"""
    DummyCoding([base[, levels]])

Dummy coding generates one indicator column (1 or 0) for each non-base level.

Columns have non-zero mean and are collinear with an intercept column (and
lower-order columns for interactions) but are orthogonal to each other. In a
regression model, dummy coding leads to an intercept that is the mean of the
dependent variable for base level.

Also known as "treatment coding" or "one-hot encoding".

# Examples

```julia
julia> StatsModels.ContrastsMatrix(DummyCoding(), ["a", "b", "c", "d"]).matrix
4×3 Array{Float64,2}:
 0.0  0.0  0.0
 1.0  0.0  0.0
 0.0  1.0  0.0
 0.0  0.0  1.0
```
"""
DummyCoding

contrasts_matrix(C::DummyCoding, baseind, n) = eye(n)[:, [1:(baseind-1); (baseind+1):n]]


"""
    EffectsCoding([base[, levels]])

Effects coding generates columns that code each non-base level as the
deviation from the base level.  For each non-base level `x` of `variable`, a
column is generated with 1 where `variable .== x` and -1 where `variable .== base`.

`EffectsCoding` is like `DummyCoding`, but using -1 for the base level instead
of 0.

When all levels are equally frequent, effects coding generates model matrix
columns that are mean centered (have mean 0).  For more than two levels the
generated columns are not orthogonal.  In a regression model with an
effects-coded variable, the intercept corresponds to the grand mean.

Also known as "sum coding" or "simple coding". Note
though that the default in R and SPSS is to use the *last* level as the base.
Here we use the *first* level as the base, for consistency with other coding
systems.

# Examples

```julia
julia> StatsModels.ContrastsMatrix(EffectsCoding(), ["a", "b", "c", "d"]).matrix
4×3 Array{Float64,2}:
 -1.0  -1.0  -1.0
  1.0   0.0   0.0
  0.0   1.0   0.0
  0.0   0.0   1.0
```

"""
EffectsCoding

function contrasts_matrix(C::EffectsCoding, baseind, n)
    not_base = [1:(baseind-1); (baseind+1):n]
    mat = eye(n)[:, not_base]
    mat[baseind, :] = -1
    return mat
end

"""
    HelmertCoding([base[, levels]])

Helmert coding codes each level as the difference from the average of the lower
levels.

For each non-base level, Helmert coding generates a columns with -1 for each of
n levels below, n for that level, and 0 above.

When all levels are equally frequent, Helmert coding generates columns that are
mean-centered (mean 0) and orthogonal.

# Examples

```julia
julia> StatsModels.ContrastsMatrix(HelmertCoding(), ["a", "b", "c", "d"]).matrix
4×3 Array{Float64,2}:
 -1.0  -1.0  -1.0
  1.0  -1.0  -1.0
  0.0   2.0  -1.0
  0.0   0.0   3.0
```
"""
HelmertCoding

function contrasts_matrix(C::HelmertCoding, baseind, n)
    mat = zeros(n, n-1)
    for i in 1:n-1
        mat[1:i, i] = -1
        mat[i+1, i] = i
    end

    # re-shuffle the rows such that base is the all -1.0 row (currently first)
    mat = mat[[baseind; 1:(baseind-1); (baseind+1):end], :]
    return mat
end

"""
    ContrastsCoding(mat::Matrix[, base[, levels]])

Coding by manual specification of contrasts matrix. For k levels, the contrasts
must be a k by k-1 Matrix.
"""
mutable struct ContrastsCoding <: AbstractContrasts
    mat::Matrix
    base::Nullable{Any}
    levels::Nullable{Vector}

    function ContrastsCoding(mat, base, levels)
        if !isnull(levels)
            check_contrasts_size(mat, length(get(levels)))
        end
        new(mat, base, levels)
    end
end

check_contrasts_size(mat::Matrix, n_lev) =
    size(mat) == (n_lev, n_lev-1) ||
    throw(ArgumentError("contrasts matrix wrong size for $n_lev levels. " *
                        "Expected $((n_lev, n_lev-1)), got $(size(mat))"))

## constructor with optional keyword arguments, defaulting to Nullables
ContrastsCoding(mat::Matrix; base=Nullable{Any}(), levels=Nullable{Vector}()) =
    ContrastsCoding(mat, nullify(base), nullify(levels))

function contrasts_matrix(C::ContrastsCoding, baseind, n)
    check_contrasts_size(C.mat, n)
    C.mat
end
