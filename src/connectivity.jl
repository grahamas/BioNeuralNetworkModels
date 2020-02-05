abstract type AbstractConnectivityParameter{T,N_CDT} <: AbstractParameter{T} end
abstract type AbstractConnectivityAction{T,N_CDT} <: AbstractSpaceInteraction{T,N_CDT} end
struct NaiveConnectivityAction{T,N_CDT,CONN,SPACE} <: AbstractConnectivityAction{T,N_CDT}
    conn::CONN
    space::SPACE
    NaiveConnectivityAction(conn::CONN, space::SPACE) where {T,N,CONN<:AbstractConnectivityParameter{T,N},SPACE<:AbstractSpace{T,N}} = begin
        validate(conn,space)
        new{T,N,CONN,SPACE}(conn,space)
    end
end
(a::AbstractConnectivityParameter)(space::AbstractSpace) = NaiveConnectivityAction(a,space)
function (a::NaiveConnectivityAction)(output, input, ignored_t)
    coords = coordinates(a.space)
    for (i_coord, coord) in enumerate(coords)
        weights = directed_weights(a.conn, a.space, coord) .* simpson_weights(a.space) .* prod(step(a.space)) # MULT BY VOL EL
        output[i_coord] += sum(weights .* input)
    end
end
        
struct FFTParameter{T,N_CDT,C<:AbstractConnectivityParameter{T,N_CDT}} <: AbstractConnectivityParameter{T,N_CDT}
    connectivity::C
    FFTParameter(c::C) where {T,N_CDT,C<:AbstractConnectivityParameter{T,N_CDT}} = new{T,N_CDT,C}(c)
end
struct FFTAction{T,N_CDT,KERN<:AbstractArray{Complex{T},N_CDT},OP,IOP} <: AbstractConnectivityAction{T,N_CDT}
    kernel::KERN
    fft_op::OP
    ifft_op::IOP
    FFTAction(kernel::KERN, fft_op::OP, ifft_op::IOP) where {T,N,KERN<:AbstractArray{Complex{T},N},OP,IOP} = new{T,N,KERN,OP,IOP}(kernel, fft_op, ifft_op)
end
# TODO: Assumes populations
function (fftp::FFTParameter)(space::AbstractSpace)
    kern = kernel(fftp.connectivity, space)
    kern_dx = kern .* prod(step(space)) # MULTIPLY BY VOLUME ELEMENT
    kernel_fftd = rfft(kern_dx)
    multi_pop_space = population_repeat(zeros(space),2)
    single_pop_zeros = population(multi_pop_space, 1)
    fft_op = plan_rfft(single_pop_zeros; flags=(FFTW.PATIENT | FFTW.UNALIGNED))
    ifft_op = plan_irfft(fft_op * single_pop_zeros, size(space,1); flags=(FFTW.PATIENT | FFTW.UNALIGNED))
    FFTAction(kernel_fftd, fft_op, ifft_op)
end
function (a::FFTAction)(output::AbstractArray, input::AbstractArray, ignored_t)
    output .+= fftshift(real(a.ifft_op * ((a.fft_op * input) .* a.kernel)))
end

abstract type AbstractExpDecayingConnectivityParameter{T,N_CDT} <: AbstractConnectivityParameter{T,N_CDT} end
(t::Type{<:AbstractExpDecayingConnectivityParameter})(; amplitude, spread) = t(amplitude, spread)
validate(a::AbstractExpDecayingConnectivityParameter, space) = (@show a.spread; @show step(space); @assert all(a.spread .> step(space)))
struct ExpAbsSumDecayingConnectivityParameter{T,N_CDT} <: AbstractExpDecayingConnectivityParameter{T,N_CDT}
    amplitude::T
    spread::NTuple{N_CDT,T}
end
struct GaussianConnectivityParameter{T,N_CDT} <: AbstractExpDecayingConnectivityParameter{T,N_CDT}
    amplitude::T
    spread::NTuple{N_CDT,T}
end

function unit_scale(arr::AbstractArray)
    @show sum(arr)
    arr ./ sum(arr)
end


# Generic functions to unpack Lattice for application of connectivity
function directed_weights(connectivity::AbstractConnectivityParameter{T,N_CDT}, locations::AbstractLattice{T,N_ARR,N_CDT},
                          source_location::NTuple{N_CDT,T}) where {T,N_ARR,N_CDT}
    diffs = differences(locations, source_location)
    center_diffs = differences(locations, coordinates(locations)[origin_idx(locations)])
    step_size = step(locations)
    return apply_connectivity(connectivity, diffs, step_size, center_diffs)
end

function apply_connectivity(connectivity::CONN, diffs::DIFFS, step_size::NTuple{N_CDT,T}, center_diffs::DIFFS) where {T,N_ARR,N_CDT,CDT<:NTuple{N_CDT,T},DIFFS<:AbstractArray{CDT,N_ARR},CONN<:ExpSumAbsDecayingConnectivityParameter{T,N_CDT}}
    unscaled = apply_connectivity_unscaled.(Ref(connectivity), diffs)
    # TODO validate use of prod
    return connectivity.amplitude .* unscaled ./ (2 * prod(connectivity.spread)) # note that stepsize is used in calling function
end

function apply_connectivity(connectivity::CONN, diffs::DIFFS, step_size::NTuple{N_CDT,T}, center_diffs::DIFFS) where {T,N_ARR,N_CDT,CDT<:NTuple{N_CDT,T},DIFFS<:AbstractArray{CDT,N_ARR},CONN<:GaussianConnectivityParameter{T,N_CDT}}
    unscaled = apply_connectivity_unscaled.(Ref(connectivity), diffs)
    scaling_diffs = apply_connectivity_unscaled.(Ref(connectivity), center_diffs)
    sum_scaling = sum(scaling_diffs)
    return connectivity.amplitude .* unscaled ./ (sqrt(prod(connectivity.spread .^ 2)) .* (2π)^(N_CDT/2))
    #return connectivity.amplitude .* (unscaled ./ sum_scaling)
end

function apply_connectivity_unscaled(conn::ExpAbsSumDecayingConnectivityParameter{T,N_CDT}, coord_differences::Tup) where {T,N_CDT,Tup<:NTuple{N_CDT,T}}
    exp(
        -abs.(sum(coord_differences ./ conn.spread)) # FIXME: Is summing after dividing by spreads right? I think so!
    )
end

function apply_connectivity_unscaled(conn::GaussianConnectivityParameter{T,N_CDT}, coord_differences::Tup) where {T,N_CDT, Tup<:NTuple{N_CDT,T}}
    exp(
        -sum( (coord_differences ./ conn.spread) .^ 2) / 2
    )
end

function kernel(conn::AbstractConnectivityParameter{T,N_CDT}, lattice::AbstractSpace{T,N_CDT}) where {T,N_CDT}
    # Kernel has ZERO DIST at its center (or floor(extent/2) + 1)
    fft_centered_differences = differences(lattice, coordinates(lattice)[fft_center_dx(lattice)])
    apply_connectivity(conn, fft_centered_differences, step(lattice), fft_centered_differences)    
end
