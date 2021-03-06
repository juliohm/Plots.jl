

# xaxis(args...; kw...) = Axis(:x, args...; kw...)
# yaxis(args...; kw...) = Axis(:y, args...; kw...)
# zaxis(args...; kw...) = Axis(:z, args...; kw...)

# -------------------------------------------------------------------------

function Axis(sp::Subplot, letter::Symbol, args...; kw...)
    # init with values from _plot_defaults
    d = KW(
        :letter => letter,
        # :extrema => (Inf, -Inf),
        :extrema => Extrema(),
        :discrete_map => Dict(),   # map discrete values to discrete indices
        :continuous_values => zeros(0),
        :use_minor => false,
        :show => true,  # show or hide the axis? (useful for linked subplots)
    )

    # get defaults from letter version, unless match
    for (k,v) in _axis_defaults
        lk = Symbol(letter, k)
        lv = _axis_defaults_byletter[lk]
        d[k] = (lv == :match ? v : lv)
    end

    # merge!(d, _axis_defaults)
    d[:discrete_values] = []

    # update the defaults
    attr!(Axis([sp], d), args...; kw...)
end

function get_axis(sp::Subplot, letter::Symbol)
    axissym = Symbol(letter, :axis)
    if haskey(sp.attr, axissym)
        sp.attr[axissym]
    else
        sp.attr[axissym] = Axis(sp, letter)
    end::Axis
end

function process_axis_arg!(d::KW, arg, letter = "")
    T = typeof(arg)
    arg = get(_scaleAliases, arg, arg)

    if typeof(arg) <: Font
        d[Symbol(letter,:tickfont)] = arg
        d[Symbol(letter,:guidefont)] = arg

    elseif arg in _allScales
        d[Symbol(letter,:scale)] = arg

    elseif arg in (:flip, :invert, :inverted)
        d[Symbol(letter,:flip)] = true

    elseif T <: AbstractString
        d[Symbol(letter,:guide)] = arg

    # xlims/ylims
    elseif (T <: Tuple || T <: AVec) && length(arg) == 2
        sym = typeof(arg[1]) <: Number ? :lims : :ticks
        d[Symbol(letter,sym)] = arg

    # xticks/yticks
    elseif T <: AVec
        d[Symbol(letter,:ticks)] = arg

    elseif arg == nothing
        d[Symbol(letter,:ticks)] = []

    elseif T <: Bool || arg in _allShowaxisArgs
        d[Symbol(letter,:showaxis)] = showaxis(arg, letter)

    elseif typeof(arg) <: Number
        d[Symbol(letter,:rotation)] = arg

    elseif typeof(arg) <: Function
        d[Symbol(letter,:formatter)] = arg

    elseif !handleColors!(d, arg, Symbol(letter, :foreground_color_axis))
        warn("Skipped $(letter)axis arg $arg")

    end
end

# update an Axis object with magic args and keywords
function attr!(axis::Axis, args...; kw...)
    # first process args
    d = axis.d
    for arg in args
        process_axis_arg!(d, arg)
    end

    # then override for any keywords... only those keywords that already exists in d
    for (k,v) in kw
        if haskey(d, k)
            if k == :discrete_values
                # add these discrete values to the axis
                for vi in v
                    discrete_value!(axis, vi)
                end
            else
                d[k] = v
            end
        end
    end

    # replace scale aliases
    if haskey(_scaleAliases, d[:scale])
        d[:scale] = _scaleAliases[d[:scale]]
    end

    axis
end

# -------------------------------------------------------------------------

Base.show(io::IO, axis::Axis) = dumpdict(axis.d, "Axis", true)
# Base.getindex(axis::Axis, k::Symbol) = getindex(axis.d, k)
Base.setindex!(axis::Axis, v, ks::Symbol...) = setindex!(axis.d, v, ks...)
Base.haskey(axis::Axis, k::Symbol) = haskey(axis.d, k)
ignorenan_extrema(axis::Axis) = (ex = axis[:extrema]; (ex.emin, ex.emax))


const _scale_funcs = Dict{Symbol,Function}(
    :log10 => log10,
    :log2 => log2,
    :ln => log,
)
const _inv_scale_funcs = Dict{Symbol,Function}(
    :log10 => exp10,
    :log2 => exp2,
    :ln => exp,
)

# const _label_func = Dict{Symbol,Function}(
#     :log10 => x -> "10^$x",
#     :log2 => x -> "2^$x",
#     :ln => x -> "e^$x",
# )

const _label_func = Dict{Symbol,Function}(
    :log10 => x -> "10^$x",
    :log2 => x -> "2^$x",
    :ln => x -> "e^$x",
)


scalefunc(scale::Symbol) = x -> get(_scale_funcs, scale, identity)(Float64(x))
invscalefunc(scale::Symbol) = x -> get(_inv_scale_funcs, scale, identity)(Float64(x))
labelfunc(scale::Symbol, backend::AbstractBackend) = get(_label_func, scale, string)

function optimal_ticks_and_labels(axis::Axis, ticks = nothing)
    amin,amax = axis_limits(axis)

    # scale the limits
    scale = axis[:scale]
    sf = scalefunc(scale)

    # If the axis input was a Date or DateTime use a special logic to find
    # "round" Date(Time)s as ticks
    # This bypasses the rest of optimal_ticks_and_labels, because
    # optimize_datetime_ticks returns ticks AND labels: the label format (Date
    # or DateTime) is chosen based on the time span between amin and amax
    # rather than on the input format
    # TODO: maybe: non-trivial scale (:ln, :log2, :log10) for date/datetime
    if ticks == nothing && scale == :identity
        if axis[:formatter] == dateformatter
            # optimize_datetime_ticks returns ticks and labels(!) based on
            # integers/floats corresponding to the DateTime type. Thus, the axes
            # limits, which resulted from converting the Date type to integers,
            # are converted to 'DateTime integers' (actually floats) before
            # being passed to optimize_datetime_ticks.
            # (convert(Int, convert(DateTime, convert(Date, i))) == 87600000*i)
            ticks, labels = optimize_datetime_ticks(864e5 * amin, 864e5 * amax;
                k_min = 2, k_max = 4)
            # Now the ticks are converted back to floats corresponding to Dates.
            return ticks / 864e5, labels
        elseif axis[:formatter] == datetimeformatter
            return optimize_datetime_ticks(amin, amax; k_min = 2, k_max = 4)
        end
    end

    # get a list of well-laid-out ticks
    if ticks == nothing
        scaled_ticks = optimize_ticks(
            sf(amin),
            sf(amax);
            k_min = 4, # minimum number of ticks
            k_max = 8, # maximum number of ticks
        )[1]
    elseif typeof(ticks) <: Int
        scaled_ticks, viewmin, viewmax = optimize_ticks(
            sf(amin),
            sf(amax);
            k_min = ticks, # minimum number of ticks
            k_max = ticks, # maximum number of ticks
            k_ideal = ticks,
            # `strict_span = false` rewards cases where the span of the
            # chosen  ticks is not too much bigger than amin - amax:
            strict_span = false,
        )
        axis[:lims] = map(invscalefunc(scale), (viewmin, viewmax))
    else
        scaled_ticks = map(sf, (filter(t -> amin <= t <= amax, ticks)))
    end
    unscaled_ticks = map(invscalefunc(scale), scaled_ticks)

    labels = if any(isfinite, unscaled_ticks)
        formatter = axis[:formatter]
        if formatter == :auto
            # the default behavior is to make strings of the scaled values and then apply the labelfunc
            map(labelfunc(scale, backend()), Showoff.showoff(scaled_ticks, :auto))
        elseif formatter == :plain
            # Leave the numbers in plain format
            map(labelfunc(scale, backend()), Showoff.showoff(scaled_ticks, :plain))
        elseif formatter == :scientific
            Showoff.showoff(unscaled_ticks, :scientific)
        else
            # there was an override for the formatter... use that on the unscaled ticks
            map(formatter, unscaled_ticks)
            # if the formatter left us with numbers, still apply the default formatter
            # However it leave us with the problem of unicode number decoding by the backend
            # if eltype(unscaled_ticks) <: Number
            #     Showoff.showoff(unscaled_ticks, :auto)
            # end
        end
    else
        # no finite ticks to show...
        String[]
    end

    # @show unscaled_ticks labels
    # labels = Showoff.showoff(unscaled_ticks, scale == :log10 ? :scientific : :auto)
    unscaled_ticks, labels
end

# return (continuous_values, discrete_values) for the ticks on this axis
function get_ticks(axis::Axis)
    ticks = _transform_ticks(axis[:ticks])
    ticks in (nothing, false) && return nothing

    # treat :native ticks as :auto
    ticks = ticks == :native ? :auto : ticks

    dvals = axis[:discrete_values]
    cv, dv = if !isempty(dvals)
        # discrete ticks...
        n = length(dvals)
        rng = if ticks == :auto
            Int[round(Int,i) for i in linspace(1, n, 15)]
        elseif ticks == :all
            1:n
        elseif typeof(ticks) <: Int
            Int[round(Int,i) for i in linspace(1, n, ticks)]
        end
        axis[:continuous_values][rng], dvals[rng]
    elseif typeof(ticks) <: Symbol
        if ispolar(axis.sps[1]) && axis[:letter] == :x
            #force theta axis to be full circle
            (collect(0:pi/4:7pi/4), string.(0:45:315))
        else
            # compute optimal ticks and labels
            optimal_ticks_and_labels(axis)
        end
    elseif typeof(ticks) <: Union{AVec, Int}
        # override ticks, but get the labels
        optimal_ticks_and_labels(axis, ticks)
    elseif typeof(ticks) <: NTuple{2, Any}
        # assuming we're passed (ticks, labels)
        ticks
    else
        error("Unknown ticks type in get_ticks: $(typeof(ticks))")
    end
    # @show ticks dvals cv dv

    return cv, dv
end

_transform_ticks(ticks) = ticks
_transform_ticks(ticks::AbstractArray{T}) where T <: Dates.TimeType = Dates.value.(ticks)
_transform_ticks(ticks::NTuple{2, Any}) = (_transform_ticks(ticks[1]), ticks[2])

# -------------------------------------------------------------------------


function reset_extrema!(sp::Subplot)
    for asym in (:x,:y,:z)
        sp[Symbol(asym,:axis)][:extrema] = Extrema()
    end
    for series in sp.series_list
        expand_extrema!(sp, series.d)
    end
end


function expand_extrema!(ex::Extrema, v::Number)
    ex.emin = isfinite(v) ? min(v, ex.emin) : ex.emin
    ex.emax = isfinite(v) ? max(v, ex.emax) : ex.emax
    ex
end

function expand_extrema!(axis::Axis, v::Number)
    expand_extrema!(axis[:extrema], v)
end

# these shouldn't impact the extrema
expand_extrema!(axis::Axis, ::Void) = axis[:extrema]
expand_extrema!(axis::Axis, ::Bool) = axis[:extrema]


function expand_extrema!(axis::Axis, v::Tuple{MIN,MAX}) where {MIN<:Number,MAX<:Number}
    ex = axis[:extrema]
    ex.emin = isfinite(v[1]) ? min(v[1], ex.emin) : ex.emin
    ex.emax = isfinite(v[2]) ? max(v[2], ex.emax) : ex.emax
    ex
end
function expand_extrema!(axis::Axis, v::AVec{N}) where N<:Number
    ex = axis[:extrema]
    for vi in v
        expand_extrema!(ex, vi)
    end
    ex
end


function expand_extrema!(sp::Subplot, d::KW)
    vert = isvertical(d)

    # first expand for the data
    for letter in (:x, :y, :z)
        data = d[if vert
            letter
        else
            letter == :x ? :y : letter == :y ? :x : :z
        end]
        if letter != :z && d[:seriestype] == :straightline && any(series[:seriestype] != :straightline for series in series_list(sp)) && data[1] != data[2]
            data = [NaN]
        end
        axis = sp[Symbol(letter, "axis")]

        if isa(data, Volume)
            expand_extrema!(sp[:xaxis], data.x_extents)
            expand_extrema!(sp[:yaxis], data.y_extents)
            expand_extrema!(sp[:zaxis], data.z_extents)
        elseif eltype(data) <: Number || (isa(data, Surface) && all(di -> isa(di, Number), data.surf))
            if !(eltype(data) <: Number)
                # huh... must have been a mis-typed surface? lets swap it out
                data = d[letter] = Surface(Matrix{Float64}(data.surf))
            end
            expand_extrema!(axis, data)
        elseif data != nothing
            # TODO: need more here... gotta track the discrete reference value
            #       as well as any coord offset (think of boxplot shape coords... they all
            #       correspond to the same x-value)
            d[letter], d[Symbol(letter,"_discrete_indices")] = discrete_value!(axis, data)
            expand_extrema!(axis, d[letter])
        end
    end

    # # expand for fillrange/bar_width
    # fillaxis, baraxis = sp.attr[:yaxis], sp.attr[:xaxis]
    # if isvertical(d)
    #     fillaxis, baraxis = baraxis, fillaxis
    # end

    # expand for fillrange
    fr = d[:fillrange]
    if fr == nothing && d[:seriestype] == :bar
        fr = 0.0
    end
    if fr != nothing && !all3D(d)
        axis = sp.attr[vert ? :yaxis : :xaxis]
        if typeof(fr) <: Tuple
            for fri in fr
                expand_extrema!(axis, fri)
            end
        else
            expand_extrema!(axis, fr)
        end
    end

    # expand for bar_width
    if d[:seriestype] == :bar
        dsym = vert ? :x : :y
        data = d[dsym]

        bw = d[:bar_width]
        if bw == nothing
            bw = d[:bar_width] = _bar_width * ignorenan_minimum(filter(x->x>0,diff(sort(data))))
        end
        axis = sp.attr[Symbol(dsym, :axis)]
        expand_extrema!(axis, ignorenan_maximum(data) + 0.5maximum(bw))
        expand_extrema!(axis, ignorenan_minimum(data) - 0.5minimum(bw))
    end

    # expand for heatmaps
    if d[:seriestype] == :heatmap
        for letter in (:x, :y)
            data = d[letter]
            axis = sp[Symbol(letter, "axis")]
            scale = get(d, Symbol(letter, "scale"), :identity)
            expand_extrema!(axis, heatmap_edges(data, scale))
        end
    end
end

function expand_extrema!(sp::Subplot, xmin, xmax, ymin, ymax)
    expand_extrema!(sp[:xaxis], (xmin, xmax))
    expand_extrema!(sp[:yaxis], (ymin, ymax))
end

# -------------------------------------------------------------------------

# push the limits out slightly
function widen(lmin, lmax)
    span = lmax - lmin
    # eps = NaNMath.max(1e-16, min(1e-2span, 1e-10))
    eps = NaNMath.max(1e-16, 0.03span)
    lmin-eps, lmax+eps
end

# figure out if widening is a good idea.  if there's a scale set it's too tricky,
# so lazy out and don't widen
function default_should_widen(axis::Axis)
    should_widen = false
    if axis[:scale] == :identity && !is_2tuple(axis[:lims])
        for sp in axis.sps
            for series in series_list(sp)
                if series.d[:seriestype] in (:scatter,) || series.d[:markershape] != :none
                    should_widen = true
                end
            end
        end
    end
    should_widen
end

# using the axis extrema and limit overrides, return the min/max value for this axis
function axis_limits(axis::Axis, should_widen::Bool = default_should_widen(axis))
    ex = axis[:extrema]
    amin, amax = ex.emin, ex.emax
    lims = axis[:lims]
    if (isa(lims, Tuple) || isa(lims, AVec)) && length(lims) == 2
        if isfinite(lims[1])
            amin = lims[1]
        end
        if isfinite(lims[2])
            amax = lims[2]
        end
    end
    if amax <= amin && isfinite(amin)
        amax = amin + 1.0
    end
    if !isfinite(amin) && !isfinite(amax)
        amin, amax = 0.0, 1.0
    end
    if ispolar(axis.sps[1])
        if axis[:letter] == :x
            amin, amax = 0, 2pi
        elseif lims == :auto
            #widen max radius so ticks dont overlap with theta axis
            amin, amax + 0.1 * abs(amax - amin)
        else
            amin, amax
        end
    elseif should_widen
        widen(amin, amax)
    else
        amin, amax
    end
end

# -------------------------------------------------------------------------

# these methods track the discrete (categorical) values which correspond to axis continuous values (cv)
# whenever we have discrete values, we automatically set the ticks to match.
# we return (continuous_value, discrete_index)
function discrete_value!(axis::Axis, dv)
    cv_idx = get(axis[:discrete_map], dv, -1)
    # @show axis[:discrete_map], axis[:discrete_values], dv
    if cv_idx == -1
        ex = axis[:extrema]
        cv = NaNMath.max(0.5, ex.emax + 1.0)
        expand_extrema!(axis, cv)
        push!(axis[:discrete_values], dv)
        push!(axis[:continuous_values], cv)
        cv_idx = length(axis[:discrete_values])
        axis[:discrete_map][dv] = cv_idx
        cv, cv_idx
    else
        cv = axis[:continuous_values][cv_idx]
        cv, cv_idx
    end
end

# continuous value... just pass back with axis negative index
function discrete_value!(axis::Axis, cv::Number)
    cv, -1
end

# add the discrete value for each item.  return the continuous values and the indices
function discrete_value!(axis::Axis, v::AVec)
    n = length(v)
    cvec = zeros(n)
    discrete_indices = zeros(Int, n)
    for i=1:n
        cvec[i], discrete_indices[i] = discrete_value!(axis, v[i])
    end
    cvec, discrete_indices
end

# add the discrete value for each item.  return the continuous values and the indices
function discrete_value!(axis::Axis, v::AMat)
    n,m = size(v)
    cmat = zeros(n,m)
    discrete_indices = zeros(Int, n, m)
    for i=1:n, j=1:m
        cmat[i,j], discrete_indices[i,j] = discrete_value!(axis, v[i,j])
    end
    cmat, discrete_indices
end

function discrete_value!(axis::Axis, v::Surface)
    map(Surface, discrete_value!(axis, v.surf))
end

# -------------------------------------------------------------------------

function pie_labels(sp::Subplot, series::Series)
    d = series.d
    if haskey(d,:x_discrete_indices)
        dvals = sp.attr[:xaxis].d[:discrete_values]
        [dvals[idx] for idx in d[:x_discrete_indices]]
    else
        d[:x]
    end
end

# -------------------------------------------------------------------------

# compute the line segments which should be drawn for this axis
function axis_drawing_info(sp::Subplot)
    xaxis, yaxis = sp[:xaxis], sp[:yaxis]
    xmin, xmax = axis_limits(xaxis)
    ymin, ymax = axis_limits(yaxis)
    xticks = get_ticks(xaxis)
    yticks = get_ticks(yaxis)
    xaxis_segs = Segments(2)
    yaxis_segs = Segments(2)
    xtick_segs = Segments(2)
    ytick_segs = Segments(2)
    xgrid_segs = Segments(2)
    ygrid_segs = Segments(2)
    xborder_segs = Segments(2)
    yborder_segs = Segments(2)

    if sp[:framestyle] != :none
        # xaxis
        if xaxis[:showaxis]
            if sp[:framestyle] != :grid
                y1, y2 = if sp[:framestyle] in (:origin, :zerolines)
                    0.0, 0.0
                else
                    xor(xaxis[:mirror], yaxis[:flip]) ? (ymax, ymin) : (ymin, ymax)
                end
                push!(xaxis_segs, (xmin, y1), (xmax, y1))
                # don't show the 0 tick label for the origin framestyle
                if sp[:framestyle] == :origin && !(xticks in (nothing,false)) && length(xticks) > 1
                    showticks = xticks[1] .!= 0
                    xticks = (xticks[1][showticks], xticks[2][showticks])
                end
            end
            sp[:framestyle] in (:semi, :box) && push!(xborder_segs, (xmin, y2), (xmax, y2)) # top spine
        end
        if !(xaxis[:ticks] in (nothing, false))
            f = scalefunc(yaxis[:scale])
            invf = invscalefunc(yaxis[:scale])
            ticks_in = xaxis[:tick_direction] == :out ? -1 : 1
            t1 = invf(f(ymin) + 0.015 * (f(ymax) - f(ymin)) * ticks_in)
            t2 = invf(f(ymax) - 0.015 * (f(ymax) - f(ymin)) * ticks_in)
            t3 = invf(f(0) + 0.015 * (f(ymax) - f(ymin)) * ticks_in)

            for xtick in xticks[1]
                if xaxis[:showaxis]
                    tick_start, tick_stop = if sp[:framestyle] == :origin
                        (0, t3)
                    else
                        xor(xaxis[:mirror], yaxis[:flip]) ? (ymax, t2) : (ymin, t1)
                    end
                    push!(xtick_segs, (xtick, tick_start), (xtick, tick_stop)) # bottom tick
                end
                # sp[:draw_axes_border] && push!(xaxis_segs, (xtick, ymax), (xtick, t2)) # top tick
                xaxis[:grid] && push!(xgrid_segs, (xtick, ymin), (xtick, ymax)) # vertical grid
            end
        end

        # yaxis
        if yaxis[:showaxis]
            if sp[:framestyle] != :grid
                x1, x2 = if sp[:framestyle] in (:origin, :zerolines)
                    0.0, 0.0
                else
                    xor(yaxis[:mirror], xaxis[:flip]) ? (xmax, xmin) : (xmin, xmax)
                end
                push!(yaxis_segs, (x1, ymin), (x1, ymax))
                # don't show the 0 tick label for the origin framestyle
                if sp[:framestyle] == :origin && !(yticks in (nothing,false)) && length(yticks) > 1
                    showticks = yticks[1] .!= 0
                    yticks = (yticks[1][showticks], yticks[2][showticks])
                end
            end
            sp[:framestyle] in (:semi, :box) && push!(yborder_segs, (x2, ymin), (x2, ymax)) # right spine
        end
        if !(yaxis[:ticks] in (nothing, false))
            f = scalefunc(xaxis[:scale])
            invf = invscalefunc(xaxis[:scale])
            ticks_in = yaxis[:tick_direction] == :out ? -1 : 1
            t1 = invf(f(xmin) + 0.015 * (f(xmax) - f(xmin)) * ticks_in)
            t2 = invf(f(xmax) - 0.015 * (f(xmax) - f(xmin)) * ticks_in)
            t3 = invf(f(0) + 0.015 * (f(xmax) - f(xmin)) * ticks_in)

            for ytick in yticks[1]
                if yaxis[:showaxis]
                    tick_start, tick_stop = if sp[:framestyle] == :origin
                        (0, t3)
                    else
                        xor(yaxis[:mirror], xaxis[:flip]) ? (xmax, t2) : (xmin, t1)
                    end
                    push!(ytick_segs, (tick_start, ytick), (tick_stop, ytick)) # left tick
                end
                # sp[:draw_axes_border] && push!(yaxis_segs, (xmax, ytick), (t2, ytick)) # right tick
                yaxis[:grid] && push!(ygrid_segs, (xmin, ytick), (xmax, ytick)) # horizontal grid
            end
        end
    end

    xticks, yticks, xaxis_segs, yaxis_segs, xtick_segs, ytick_segs, xgrid_segs, ygrid_segs, xborder_segs, yborder_segs
end
