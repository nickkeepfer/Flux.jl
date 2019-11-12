# Arrays
glorot_uniform(dims...) = (rand(Float32, dims...) .- 0.5f0) .* sqrt(24.0f0/sum(dims))
glorot_normal(dims...) = randn(Float32, dims...) .* sqrt(2.0f0/sum(dims))

ones(T::Type, dims...) = Base.ones(T, dims...)
zeros(T::Type, dims...) = Base.zeros(T, dims...)

ones(dims...) = Base.ones(Float32, dims...)
zeros(dims...) = Base.zeros(Float32, dims...)

unsqueeze(xs, dim) = reshape(xs, (size(xs)[1:dim-1]..., 1, size(xs)[dim:end]...))

stack(xs, dim) = cat(unsqueeze.(xs, dim)..., dims=dim)
unstack(xs, dim) = [copy(selectdim(xs, dim, i)) for i in 1:size(xs, dim)]

"""
    chunk(xs, n)

Split `xs` into `n` parts.

```julia
julia> chunk(1:10, 3)
3-element Array{Array{Int64,1},1}:
 [1, 2, 3, 4]
 [5, 6, 7, 8]
 [9, 10]
```
"""
chunk(xs, n) = collect(Iterators.partition(xs, ceil(Int, length(xs)/n)))

batchindex(xs, i) = (reverse(Base.tail(reverse(axes(xs))))..., i)

"""
    frequencies(xs)

Count the number of times that each element of `xs` appears.

```julia
julia> frequencies(['a','b','b'])
Dict{Char,Int64} with 2 entries:
  'b' => 2
  'a' => 1
```
"""
function frequencies(xs)
  fs = Dict{eltype(xs),Int}()
  for x in xs
    fs[x] = get(fs, x, 0) + 1
  end
  return fs
end

head(x::Tuple) = reverse(Base.tail(reverse(x)))

squeezebatch(x) = reshape(x, head(size(x)))

"""
  batch(xs)

Batch the arrays in `xs` into a single array.

```julia
julia> batch([[1,2,3],[4,5,6]])
3×2 Array{Int64,2}:
 1  4
 2  5
 3  6
```
"""
function batch(xs)
  data = first(xs) isa AbstractArray ?
    similar(first(xs), size(first(xs))..., length(xs)) :
    Vector{eltype(xs)}(undef, length(xs))
  for (i, x) in enumerate(xs)
    data[batchindex(data, i)...] = x
  end
  return data
end

Base.rpad(v::AbstractVector, n::Integer, p) = [v; fill(p, max(n - length(v), 0))]

"""
    batchseq(seqs, pad)

Take a list of `N` sequences, and turn them into a single sequence where each
item is a batch of `N`. Short sequences will be padded by `pad`.

```julia
julia> batchseq([[1, 2, 3], [4, 5]], 0)
3-element Array{Array{Int64,1},1}:
 [1, 4]
 [2, 5]
 [3, 0]
```
"""
function batchseq(xs, pad = nothing, n = maximum(length(x) for x in xs))
  xs_ = [rpad(x, n, pad) for x in xs]
  [batch([xs_[j][i] for j = 1:length(xs_)]) for i = 1:n]
end

# Other

"""
Returns a function that when invoked, will only be triggered at most once
during `timeout` seconds. Normally, the throttled function will run
as much as it can, without ever going more than once per `wait` duration;
but if you'd like to disable the execution on the leading edge, pass
`leading=false`. To enable execution on the trailing edge, ditto.
"""
function throttle(f, timeout; leading=true, trailing=false)
  cooldown = true
  later = nothing
  result = nothing

  function throttled(args...; kwargs...)
    yield()

    if cooldown
      if leading
        result = f(args...; kwargs...)
      else
        later = () -> f(args...; kwargs...)
      end

      cooldown = false
      @async try
        while (sleep(timeout); later != nothing)
          later()
          later = nothing
        end
      finally
        cooldown = true
      end
    elseif trailing
      later = () -> (result = f(args...; kwargs...))
    end

    return result
  end
end

import Base: +, -, *, reshape, size
import Base.Broadcast: broadcasted, Broadcasted, BroadcastStyle

"""
    Zeros()
    Zeros(size...)
    Zeros(Type, size...)

Acts as a stand-in for an array of zeros that can be
used during training which is ignored by the optimisers.

Useful to turn bias off for a forward pass of a layer.

!!! warning
    Zeros acts a scalar while broadcasting, so does not
    expand dims. Checks for shape compatibility by default.

## Examples

```julia
julia> Flux.Zeros(3,3)
3×3 Flux.Zeros{Bool,2}:
 false  false  false
 false  false  false
 false  false  false

julia> Flux.Zeros(Float32, 3,3)
3×3 Flux.Zeros{Float32,2}:
 0.0  0.0  0.0
 0.0  0.0  0.0
 0.0  0.0  0.0

julia> rand(3,3) .+ Flux.Zeros()
3×3 Array{Float64,2}:
 0.198739  0.490459  0.785386
 0.779074  0.39986   0.66383
 0.854981  0.447292  0.314497

julia> bias_less_conv = Conv((2,2), 1=>3, bias = Flux.Zeros())
Conv((2, 2), 1=>3)
```
"""
struct Zeros{T,N} <: AbstractArray{T,N}
  size::Tuple
end

Zeros(::Type{T}, sz...) where T = Zeros{T,length(sz)}(sz)
Zeros(sz::Integer...) = Zeros(Bool, sz...)

Base.size(xs::Zeros) = xs.size
Base.axes(xs::Zeros) = Base.OneTo.(size(xs))

Base.IndexStyle(::Type{<:Zeros}) = IndexCartesian()

Base.getindex(xs::Zeros{T,N}, I::Vararg{Int, N}) where {T,N} = zero(T)
Base.getindex(xs::Zeros{T,N}, inds::Union{Base.OneTo, Base.UnitRange}) where {T,N} =
  Zeros(T, inds.stop)

Base.setindex(xs::Zeros, args...) =
  error("setindex disallowed on Zeros Array")
Base.setindex!(xs::Zeros, args...) =
  error("setindex! disallowed on Zeros Array")

Base.collect(xs::Zeros{T,N}) where {T,N} = fill(zero(T), size(xs))

# Ignore during backwards pass
@adjoint reshape(xs::Zeros{T}, dims...) where T =
  reshape(xs, dims...), _ -> nothing

# Define basic ops
for f in (:+, :-)
 @eval $f(a::Union{AbstractArray{<:Number}, Zeros}, b::Zeros) = a
end
Base.:+(a::Zeros, b::AbstractArray) = b
Base.:-(a::Zeros, b::AbstractArray) = -b
Base.:*(a::Union{AbstractArray{<:Number}, Zeros}, b::Zeros) = zero(a)
Base.:*(a::Zeros, b::AbstractArray) = zero(b)

# Hook into broadcasting API - to allow using as a regular array
Base.BroadcastStyle(::Type{<:Zeros}) = Broadcast.ArrayStyle{Zeros}()
Broadcast.broadcastable(xs::Zeros) = xs
Base.BroadcastStyle(::Broadcast.ArrayStyle{Zeros}, ::Broadcast.DefaultArrayStyle{N}) where N =
  Broadcast.ArrayStyle{Zeros}()

function Base.similar(bc::Broadcasted{Broadcast.ArrayStyle{Flux.Zeros}}, ::Type{T}) where T
  similar(Array{T}, axes(bc))
end

Base.copy(xs::Zeros{T,N}) where {T,N} = Zeros(T, size(xs)...)

isZeros(x::Zeros) = true
isZeros(x) = false

function Base.copyto!(dest::AbstractArray, bc::Broadcasted{Broadcast.ArrayStyle{Flux.Zeros}})
  bc = Broadcast.flatten(bc)

  i = isZeros(first(bc.args)) ? 2 : 1 # findfirst(!isZeros, bc.args)
  dest .= bc.args[i]
end

"""
    @jit ...

The `@jit` annotation can be applied to any code, and the code will be compiled
for performance.

    @jit f(x) = @jit(x) + @jit(x)

Note that compilation happens regardless of the `@jit` macro, so it should only
be used for aesthetic purposes, or by recovering Python users.
"""
macro jit(ex)
  esc(ex)
end
