struct SingleOrder
    hour::Int64                         # Hour for single order
    independent_volume::Real            # Price independent order volume
    dependent_volumes::AbstractVector   # Price dependent order volume
    prices::AbstractVector              # Price dependent order prices
end
independent(order::SingleOrder) = order.independent_volume
dependent(order::SingleOrder) = order.dependent_volumes[2:end-1]
lowertechnical(order::SingleOrder) = order.dependent_volumes[1]
uppertechnical(order::SingleOrder) = order.dependent_volumes[end]

struct BlockOrder
    interval::Tuple{Int64,Int64}   # Time range for block order
    volume::Real                   # Asked volume for block order
    price::Real                    # Asked price for block order
end

struct OrderStrategy
    horizon::Horizon                  # Planning horizon
    prices::AbstractVector            # Possible prices levels

    single_orders::Vector{SingleOrder}   # Order orders each hour
    block_orders::Vector{BlockOrder}     # All block orders
end

function OrderStrategy(horizon::Horizon,regulations::TradeRegulations,prices::Vector{Float64},model::JuMPModel)
    @assert haskey(model.objDict,:xt_i) && haskey(model.objDict,:xt_d) && haskey(model.objDict,:xb) "Given JuMP model does not model order strategies"
    blockprices = prices[2:end-1]

    xt_i = getvalue(model.objDict[:xt_i])
    xt_d = getvalue(model.objDict[:xt_d])
    xb = getvalue(model.objDict[:xb])

    # Check data length consistency
    hs = 1:hours(horizon)
    hours_per_block = [collect(h:ending) for h in hs for ending in hs[h+regulations.blockminlength-1:end]]
    @assert hours(horizon) == length(xt_i) "Incorrect horizon of price independent single orders"
    @assert hours(horizon) == JuMP.size(xt_d)[2] "Incorrect horizon of price dependent single orders"
    @assert length(hours_per_block) == JuMP.size(xb)[2] "Incorrect horizon of block orders"
    @assert length(prices) == JuMP.size(xt_d)[1] "Incorrect number of possible orders in price dependent single orders"
    @assert length(blockprices) == JuMP.size(xb)[1] "Incorrect number of possible orders in block orders"

    # Accumulate orders per hour
    single_orders = Vector{SingleOrder}(hours(horizon))
    for hour in 1:hours(horizon)
        single_d = [xt_d[order,hour] for order = 1:length(prices)]
        single_orders[hour] = SingleOrder(hour,xt_i[hour],single_d,prices)
    end

    block_orders = Vector{BlockOrder}()
    for (i,price) in enumerate(blockprices)
        for (j,interval) in enumerate(hours_per_block)
            ordervolume = xb[i,j]
            if ordervolume > 1e-6
                push!(block_orders,BlockOrder(tuple(interval[1]-1,interval[end]),ordervolume,price))
            end
        end
    end

    return OrderStrategy(horizon,
                       prices,
                       single_orders,
                       block_orders)
end

function singleorder(strategy::OrderStrategy,hour::Int64)
    if hour > 0 && hour <= hours(strategy.horizon)
        return strategy.single_orders[hour]
    else
        throw(ArgumentError(string("Selected hour ",hour," not within horizon 1 to ",hours(strategy.horizon))))
    end
end
singleorders(strategy::OrderStrategy) = strategy.single_orders
blockorders(strategy::OrderStrategy) = strategy.block_orders
function volumes(strategy::OrderStrategy)
    fromBlock = (block,hour) -> (hour >= block.interval[1]+1 && hour <= block.interval[2]) ? block.volume : 0
    return [strategy.single_orders[hour].independent_volume + maximum(strategy.single_orders[hour].dependent_volumes) + sum([fromBlock(block,hour) for block in strategy.block_orders])
            for hour in 1:hours(strategy.horizon)]
end

function production(strategy::OrderStrategy,ρs::AbstractVector)
    H = zeros(hours(strategy.horizon))
    accepted_blocks = blockorders(strategy)[find((o) -> o.price <= mean(ρs[o.interval[1]+1:o.interval[2]]),blockorders(strategy))]
    for h = 1:hours(strategy.horizon)
        ρ = ρs[h]
        single = singleorder(strategy,h)
        H[h] = independent(single)
        for i = 2:length(single.prices)
            p1 = single.prices[i-1]
            p2 = single.prices[i]
            if p1 <= ρ < p2 || p1 < ρ <= p2
                H[h] += ((ρ - p1)/(p2 - p1))*single.dependent_volumes[i] + ((p2 - ρ)/(p2 - p1))*single.dependent_volumes[i-1]
                break
            end
        end
        blocks_in_hour = find(o -> (o.interval[1]+1 <= h <= o.interval[2]),accepted_blocks)
        H[h] += sum([order.volume for order in accepted_blocks[blocks_in_hour]])
    end
    return H
end
totalproduction(strategy::OrderStrategy,ρ::AbstractVector) = sum(production(strategy,ρ))

revenue(strategy::OrderStrategy,ρs::AbstractVector) = production(strategy,ρs) .* ρs
totalrevenue(strategy::OrderStrategy,ρs) = production(strategy,ρs) ⋅ ρs

## Print / Plot routines ##
# ===================================================== #
function show(io::IO, ::MIME"text/plain", order::SingleOrder)
    show(io,order)
end

function show(io::IO, order::SingleOrder)
    formatter = (d) -> begin
        if abs(d) <= sqrt(eps())
            "0.0"
        elseif (log10(d) < -2.0 || log10(d) > 3.0)
            @sprintf("%.2e",d)
        else
            @sprintf("%.2f",d)
        end
    end
    if get(io, :multiline, false)
        print(io,@sprintf("Single Order"))
    else
        output = @sprintf("Single Order \nHour: %d \n",order.hour)
        output *= @sprintf("Price Independent Order Volume [MWh/h]: %s \n",formatter(order.independent_volume))
        output *= "Price Dependent Order Volumes [EUR/MWh -> MWh/h]: \n"
        for (price,volume) in zip(order.prices[2:end-1],order.dependent_volumes[2:end-1])
            output *= @sprintf(" %s -> %s \n",formatter(price),formatter(volume))
        end
    end
    print(io,chomp(output))
end

@recipe f(order::SingleOrder) = (order,[])
@recipe f(order::SingleOrder,ρ::Real) = (order,[ρ])
@recipe f(order::SingleOrder,ρs...) = (order,[ρs...])
@recipe function f(order::SingleOrder,ρs::AbstractVector)
    hour = order.hour
    orderincrement = mean(abs.(diff(order.prices[2:end-1])))
    maxorder = max(order.independent_volume,maximum(order.dependent_volumes))

    line_v = []
    line_p = []
    interp_v = []
    interp_p = []
    for (v,volume) in enumerate(order.dependent_volumes)
        if v == 1 && volume == 0
            append!(line_v,fill(volume,2))
            append!(line_p,[0,order.prices[1]])
        end
        if v > 1
            previous = order.dependent_volumes[v-1]
            if !(abs(volume-previous) <= eps())
                # Horizontal strip
                append!(line_v,[previous,volume])
                append!(line_p,fill(order.prices[v],2))
                # Interpolation line
                if any(ρ -> (order.prices[v-1] <= ρ <= order.prices[v]),ρs)
                    push!(interp_v,[previous,volume])
                    push!(interp_p,[order.prices[v-1],order.prices[v]])
                end
            else
                append!(line_v,fill(volume,2))
                price = [order.prices[v-1],order.prices[v]]
                append!(line_p,price)
            end
        end
    end

    v_outcomes = zeros(eltype(order.dependent_volumes),length(ρs))
    if !isempty(ρs)
        # Plot all resulting trading outcomes for the given prices
        for (i,ρ) in enumerate(ρs)
            if ρ < order.prices[1] || ρ > order.prices[end]
                v_outcomes[i] = 0
                continue
            end
            for p = 2:length(order.prices)
                p1 = order.prices[p-1]
                p2 = order.prices[p]
                if p1 <= ρ <= p2
                    v_outcomes[i] = ((ρ - p1)/(p2 - p1))*order.dependent_volumes[p] + ((p2 - ρ)/(p2 - p1))*order.dependent_volumes[p-1]
                end
            end
        end
    end

    # Plot attributes
    xticks := linspace(0,maxorder,length(order.prices))
    yticks := 0:orderincrement:order.prices[end-1]
    ylims := (-orderincrement,order.prices[end-1]+orderincrement)
    formatter := (d) -> @sprintf("%.2f",d)
    tickfont := font(14,"sans-serif")

    title := "Order Curve"
    xlabel := "Order Volume [MWh/h]"
    ylabel := "Price [EUR/MWh]"
    tickfont := font(14,"sans-serif")
    guidefont := font(16,"sans-serif")
    titlefont := font(18,"sans-serif")
    legendfont := font(16,"sans-serif")

    # Dashed line
    if !isempty(line_v)
        @series begin
            linestyle := :solid
            linewidth := 2
            linecolor := :black
            label := ""
            line_v,line_p
        end
    end

    # Price independent order
    @series begin
        markercolor --> :green
        markersize --> 8
        seriestype := :scatter
        label := "Price Independent Order"

        [order.independent_volume],[0]
    end

    if any(v->v >= eps(),order.dependent_volumes)
        # Display the individual orders
        @series begin
            markercolor := :brown
            markersize := 8
            seriestype := :scatter
            label := "Price Dependent Order"

            order.dependent_volumes,order.prices
        end
    end

    # Interpolation line
    if !isempty(interp_v)
        @series begin
            linestyle := :dash
            linewidth := 1
            linecolor := :black
            label := ""
            interp_v,interp_p
        end
    end

    # Display the trading outcomes
    if !isempty(v_outcomes)
        @series begin
            markercolor := :green
            markershape := :diamond
            markersize := 8
            seriestype := :scatter
            if length(ρs) > 1
                label := "Trading Outcomes"
            else
                label := "Trading Outcome"
            end
            v_outcomes,ρs
        end
    end
end

@recipe f(orders::Vector{SingleOrder}) = (orders,[])
@recipe f(orders::Vector{SingleOrder},ρ::Real) = (orders,[ρ])
@recipe f(orders::Vector{SingleOrder},ρs...) = (orders,[ρs...])
@recipe function f(orders::Vector{SingleOrder},ρs::AbstractVector; annotationfontsize = 12)
    prices = orders[1].prices
    orderincrement = mean(abs.(diff(prices[2:end-1])))
    ρ_min = !isempty(ρs) ? minimum(ρs) : []
    ρ_max = !isempty(ρs) ? maximum(ρs) : []
    δρ = !isempty(ρs) ? mean(abs.(diff(ρs))) : []

    rect(x,y,w,h) = Shape(x + [0,w,w,0,0],y + [0,0,h,h,0])
    formatter = (d) -> begin
        if abs(d) <= sqrt(eps())
            text("0.0",font(annotationfontsize,"sans-serif",:white))
        elseif (log10(d) < -2.0 || log10(d) > 3.0)
            text(@sprintf("%.2e",d),font(annotationfontsize,"sans-serif",-π/2,:white))
        elseif log10(d) > 2.0
            text(@sprintf("%.1f",d),font(annotationfontsize,"sans-serif",:white))
        else
            text(@sprintf("%.2f",d),font(annotationfontsize,"sans-serif",:white))
        end
    end

    independent_bars = Shape[]
    dependent_bars = Shape[]
    ordervolumes = []
    accepted = Int64[]
    rejected = Int64[]
    for order in orders
        if order.independent_volume >= sqrt(eps())
            push!(independent_bars,rect(order.hour-1,-orderincrement,1.0,orderincrement))
            push!(ordervolumes,(order.hour-0.5,-orderincrement/2,formatter(order.independent_volume)))
        end
        firstpos = findfirst(a -> a >= sqrt(eps()),order.dependent_volumes)
        if firstpos == 0
            continue
        end
        if !any(a -> a >= sqrt(eps()),order.dependent_volumes)
            continue
        end
        start = !isempty(ρs) ? order.prices[1] : 0.0
        stop = 0.0
        splitfound = false
        if !isempty(ρs)
            ρ = ρs[order.hour]
            for i = 2:length(order.dependent_volumes)
                volume = order.dependent_volumes[i]
                previous = order.dependent_volumes[i-1]
                stop = order.prices[i]
                if !splitfound && start <= ρ
                    if start <= ρ <= stop
                        interp_volume = ((ρ - start)/(stop - start))*volume + ((stop - ρ)/(stop - start))*previous
                        stop = ρ
                        start = 0
                        if abs(interp_volume) <= sqrt(eps())
                            start = ρ
                            break
                        end
                        push!(accepted,length(dependent_bars)+1)
                        push!(dependent_bars,rect(order.hour-1,start,1.0,stop-start))
                        push!(ordervolumes,(order.hour-0.5,(start+stop)/2,formatter(interp_volume)))
                        start = stop
                        splitfound = true
                        break
                    else
                        if !(abs(volume-previous) <= sqrt(eps()))
                            start = stop
                        end
                    end
                end
            end
        else
            for i = firstpos:length(order.dependent_volumes)-1
                volume = order.dependent_volumes[i]
                previous = order.dependent_volumes[i-1]
                stop = order.prices[i]
                if !(abs(volume-previous) <= sqrt(eps())) || i == length(order.dependent_volumes)-1
                    push!(dependent_bars,rect(order.hour-1,start,1.0,stop-start))
                    push!(ordervolumes,(order.hour-0.5,(start+stop)/2,formatter(previous)))
                    start = stop
                end
            end
        end

        if !isempty(ρs)
            stop = prices[end]
            push!(rejected,length(dependent_bars)+1)
            push!(dependent_bars,rect(order.hour-1,start,1.0,stop-start))
        end
    end

    height = prices[end-1]+2*orderincrement
    # Independent Volume label
    push!(independent_bars,rect(25,-orderincrement,1.0,0.5*height))
    push!(ordervolumes,(25.5,0.25*height-orderincrement,text("Independent Volume [MWh]",font(annotationfontsize,"sans-serif",-π/2,:white))))
    # Dependent Volume label
    push!(accepted,length(dependent_bars)+1)
    push!(dependent_bars,rect(25,0.5*height-orderincrement,1.0,0.5*height))
    push!(ordervolumes,(25.5,0.75*height-orderincrement,text("Dependent Volumes [Mwh]",font(annotationfontsize,"sans-serif",-π/2,:white))))

    # Plot attributes
    xticks := collect(0:24)
    xlims := (-1,26)
    ylims --> (-orderincrement,prices[end-1]+orderincrement)
    if !isempty(ρs)
        yticks := 0:mean([δρ,orderincrement]):prices[end-1]+orderincrement
    else
        yticks := 0:orderincrement:prices[end]
    end
    tickfont := font(14,"sans-serif")
    guidefont := font(16,"sans-serif")
    titlefont := font(22,"sans-serif")
    legendfont := font(16,"sans-serif")
    legend := :topleft
    annotations := ordervolumes
    yformatter := (d) -> @sprintf("%.2f",d)
    # left_margin --> -50px
    # bottom_margin --> -30px

    title := "Single Orders"
    xlabel := "Hour"
    ylabel := "Price [EUR/MWh]"

    # Always show the price independent orders
    @series begin
        seriestype := :shape
        seriescolor := :green
        label := ""
        independent_bars
    end

    if !isempty(ρs)
        # Accepted orders
        @series begin
            seriestype := :shape
            seriescolor := :green
            label := "Accepted Orders"
            dependent_bars[accepted]
        end
        # Rejected orders
        @series begin
            seriestype := :shape
            seriescolor := :red
            label := "Rejected Orders"
            dependent_bars[rejected]
        end
        # Show the price curve
        @series begin
            seriestype := :scatter
            seriescolor := :green
            label := "Market price"
            collect(0.5:1:23.5),ρs
        end
        @series begin
            seriestype := :path
            seriescolor := :green
            label := ""
            collect(0.5:1:23.5),ρs
        end
    else
        # Show all price dependent orders if no prices given
        @series begin
            seriestype := :shape
            seriescolor := :brown
            label := ""
            dependent_bars
        end
    end
end

function show(io::IO, ::MIME"text/plain", order::BlockOrder)
    show(io,order)
end

function show(io::IO, order::BlockOrder)
    formatter = (d) -> begin
        if abs(d) <= sqrt(eps())
            "0.0"
        elseif (log10(d) < -2.0 || log10(d) > 3.0)
            @sprintf("%.2e",d)
        else
            @sprintf("%.2f",d)
        end
    end
    if get(io, :multiline, false)
        print(io,"Block Order")
    else
        output = "Block Order\n"
        output *= string("Interval: ",order.interval[1]," - ",order.interval[2],"\n")
        if order.volume >= eps()
                        output *= @sprintf("Order Volume [MWh/h]: %s \n",formatter(order.volume))
        else
            output *= "Order Volume [MWh/h]: 0\n"
        end
        output *= @sprintf("Price [EUR/MWh]: %s",formatter(order.price))
    end
    print(io,output)
end

@recipe f(order::BlockOrder) = order,[]
@recipe function f(order::BlockOrder,ρs::AbstractVector; annotationfontsize = 14)
    ρ_min = !isempty(ρs) ? minimum(ρs) : []
    ρ_max = !isempty(ρs) ? maximum(ρs) : []
    δρ = !isempty(ρs) ? mean(abs.(diff(ρs))) : []
    p_max = order.price + δρ
    highest = !isempty(ρs) ? max(p_max,ρ_max) : p_max
    annotation_font = font(annotationfontsize,"sans-serif",:white)
    formatter = (d) -> begin
        if abs(d) <= sqrt(eps())
            text("0.0",font(annotationfontsize,"sans-serif",:white))
        elseif (log10(d) < -2.0 || log10(d) > 3.0)
            text(@sprintf("%.2e",d),annotation_font)
        elseif log10(d) > 2.0
            text(@sprintf("%.1f",d),annotation_font)
        else
            text(@sprintf("%.2f",d),annotation_font)
        end
    end

    price = order.price
    width = order.interval[2]-order.interval[1]
    height = order.price/10
    color = :red
    status = "Rejected Order"
    padding = !isempty(ρs) ? 1.5 : 2*(order.interval[2]-order.interval[1])/24

    if !isempty(ρs)
        ρ̅ = mean(ρs[order.interval[1]+1:order.interval[2]])
        if order.price <= ρ̅
            price = ρ̅
            color = :green
            status = "Accepted Order"
        else
            δρ *= 4
        end
    end

    # Plot attributes
    ylims := (0,2*price)
    xticks := [order.interval...]
    if !isempty(ρs)
        xlims := -1:1:24
        ylims := (ρ_min-δρ,highest+δρ)
        if δρ >= eps()
            yticks := ρ_min:δρ:highest+δρ
        else
            yticks := []
        end
    else
        xlims := (order.interval[1]-1,order.interval[2]+1)
        yticks := []
    end
    title := "Block Order"
    tickfont := font(14,"sans-serif")
    guidefont := font(16,"sans-serif")
    legendfont := font(16,"sans-serif")
    titlefont := font(22,"sans-serif")
    title := "Block Order"
    xlabel := "Hour"
    ylabel := !isempty(ρs) ? "Price [EUR/MWh]" : ""
    yformatter --> (d) -> @sprintf("%.2f",d)
    annotations --> [(order.interval[1]+padding,price,text(@sprintf("%.2f [EUR/MWh]",order.price),annotation_font)),
                     (order.interval[2]-padding,price,text(@sprintf("%.2f [MWh/h]",order.volume),annotation_font))]

    if !isempty(ρs)
        # Accepted/Rejected orders
        @series begin
            seriestype := :shape
            seriescolor := color
            label := status
            Shape(order.interval[1] + [0,width,width,0,0],price-height/2 + [0,0,height,height,0])
        end
        # Show the price curve
        @series begin
            seriestype := :scatter
            seriescolor := :green
            label := "Market price"
            collect(0.5:1:23.5),ρs
        end
        @series begin
            seriestype := :path
            seriescolor := :green
            label := ""
            collect(0.5:1:23.5),ρs
        end
    else
        @series begin
            seriestype := :shape
            seriescolor := :brown
            label := ""
            Shape(order.interval[1] + [0,width,width,0,0],order.price-height/2 + [0,0,height,height,0])
        end
    end
end

@recipe f(orders::Vector{BlockOrder}) = orders,[]
@recipe function f(orders::Vector{BlockOrder},ρs::AbstractVector; annotationfontsize = 14)
    if !isempty(ρs) && length(ρs) != 24
        throw(ArgumentError("Need to supply a price vector for the whole day when showing block orders"))
    end
    ρ_min = !isempty(ρs) ? minimum(ρs) : []
    ρ_max = !isempty(ρs) ? maximum(ρs) : []
    δρ = !isempty(ρs) ? mean(abs.(diff(ρs))) : []
    p_max = maximum([order.price for order in orders]) + δρ
    highest = !isempty(ρs) ? max(p_max,ρ_max) : p_max
    levels = collect(1:1:length(orders))
    sorted = sort(orders,by=(order)->order.price)
    annotation_font = font(annotationfontsize,"sans-serif",:white)
    formatter = (d) -> begin
        if abs(d) <= sqrt(eps())
            text("0.0",font(annotationfontsize,"sans-serif",:white))
        elseif (log10(d) < -2.0 || log10(d) > 3.0)
            text(@sprintf("%.2e",d),annotation_font)
        elseif log10(d) > 2.0
            text(@sprintf("%.1f",d),annotation_font)
        else
            text(@sprintf("%.2f",d),annotation_font)
        end
    end
    plain_orders = Shape[]
    accepted_blocks = Shape[]
    rejected_blocks = []
    rejected_prices = []
    orderinfos = []

    rect(x,y,w,h) = Shape(x + [0,w,w,0,0],y + [0,0,h,h,0])
    if !isempty(ρs)
        accepted = find(o -> o.price <= mean(ρs[o.interval[1]+1:o.interval[2]]),orders)
        if isempty(accepted)
            δρ *= 4
        end
        accepted_orders = [BlockOrder(order.interval,sum([same.volume for same in orders[accepted][find(o -> o.interval == order.interval,orders[accepted])]]),order.price) for order in unique(o -> o.interval,orders[accepted])]
        rejected_orders = orders[setdiff(1:length(orders),accepted)]
        for order in accepted_orders
            width = order.interval[2]-order.interval[1]
            ρ̅ = mean(ρs[order.interval[1]+1:order.interval[2]])
            push!(accepted_blocks,rect(order.interval[1],ρ̅-δρ/4,width,δρ/2))
            push!(orderinfos,(order.interval[1]+0.5,ρ̅,formatter(ρ̅)))
            push!(orderinfos,(order.interval[2]-0.5,ρ̅,formatter(order.volume)))
        end
        for order in rejected_orders
            append!(rejected_blocks,[order.interval...])
            push!(rejected_blocks,NaN)
            append!(rejected_prices,fill(order.price,2))
            push!(rejected_prices,NaN)
        end
    else
        for (level,order) in zip(levels,sorted)
            width = order.interval[2]-order.interval[1]
            push!(plain_orders,rect(order.interval[1],level-0.5,width,1.0))
            push!(orderinfos,(order.interval[1]+0.5,level,formatter(order.price)))
            push!(orderinfos,(order.interval[2]-0.5,level,formatter(order.volume)))
        end
    end

    # Legend
    if !isempty(ρs)
        append!(orderinfos,[(20.5,highest+3*δρ/4,text("Price [EUR/MWh]",annotation_font)),(24.5,highest+3*δρ/4,text("Volume [MWh/h]",annotation_font))])
    else
        append!(orderinfos,[(20.5,length(orders)+2.5,text("Price [EUR/MWh]",annotation_font)),(24.5,length(orders)+2.5,text("Volume [MWh/h]",annotation_font))])
    end
    legendline = if !isempty(ρs)
        rect(19,highest+δρ/2,7,δρ/2)
    else
        rect(19,length(orders)+2,7,1.0)
    end

    # Plot attributes
    xlims := (-1,26)
    xticks := 0:1:24
    if !isempty(ρs)
        ylims := (ρ_min-δρ,highest+δρ)
        if δρ >= eps()
            yticks := ρ_min:δρ:highest+δρ
        else
            yticks := []
        end
    else
        ylims := (-1,length(orders)+3)
        yticks := []
    end
    yformatter := (d) -> @sprintf("%.2f",d)
    tickfont := font(14,"sans-serif")
    guidefont := font(16,"sans-serif")
    legendfont := font(16,"sans-serif")
    titlefont := font(22,"sans-serif")
    title := "Block Orders"
    xlabel := "Hour"
    ylabel := !isempty(ρs) ? "Price [EUR/MWh]" : ""
    annotations --> orderinfos

    # Legend
    if !isempty(ρs)
        @series begin
            seriestype := :shape
            seriescolor := :green
            label := ""
            legendline
        end
    else
        @series begin
            seriestype := :shape
            seriescolor := :brown
            label := ""
            legendline
        end
    end

    # Block orders
    if !isempty(ρs)
        # Display which orders are accepted/rejected
        # Accepted orders
        if !isempty(accepted_blocks)
            @series begin
                seriestype := :shape
                seriescolor := :green
                label := "Accepted Orders"
                accepted_blocks
            end
        end
        # Rejected orders
        if !isempty(rejected_blocks)
            @series begin
                linewidth := 4
                linecolor := :red
                seriestype := :shape
                seriescolor := :red
                label := "Rejected Orders"
                rejected_blocks,rejected_prices
            end
        end
        # Show the price curve
        @series begin
            seriestype := :scatter
            seriescolor := :green
            label := "Market price"
            collect(0.5:1:23.5),ρs
        end
        @series begin
            seriestype := :path
            seriescolor := :green
            label := ""
            collect(0.5:1:23.5),ρs
        end
    else
        # Show all orders
        @series begin
            seriestype := :shape
            seriescolor := :brown
            label := ""
            plain_orders
        end
    end
end

function show(io::IO, ::MIME"text/plain", strategy::OrderStrategy)
    show(io,strategy)
end

function show(io::IO, strategy::OrderStrategy)
    if get(io, :multiline, false)
        print(io,"Order Strategy")
    else
        println(io,"Order Strategy")
        println(io,"Price levels:")
        Base.print_matrix(io,strategy.prices)
    end
end

@recipe f(strategy::OrderStrategy) = strategy,[]
@recipe function f(strategy::OrderStrategy,ρs::AbstractVector)
    if !isempty(ρs) && length(ρs) != 24
        throw(ArgumentError("Need to supply a price vector for the whole day when showing block orders"))
    end
    prices = strategy.prices
    orderincrement = mean(abs.(diff(prices)))

    if !isempty(ρs)
        legend := :topleft
    end
    layout := (2,1)
    link := :x

    @series begin
        title := "Single Orders"
        annotationfontsize := 9
        subplot := 1
        strategy.single_orders,ρs
    end

    @series begin
        title := "Block Orders"
        annotationfontsize := 10
        subplot := 2
        strategy.block_orders,ρs
    end
end