import LinearAlgebra

# MAP DATA MODEL DOWN

function map_down_data_model(data_model_user)
    data_model = deepcopy(data_model_user)
    data_model = data_model_user

    !haskey(data_model, "mappings")

    _expand_linecode!(data_model)
    add_mappings!(data_model, "load_to_shunt", _load_to_shunt!(data_model))
    add_mappings!(data_model, "capacitor_to_shunt", _capacitor_to_shunt!(data_model))
    add_mappings!(data_model, "decompose_transformer_nw", _decompose_transformer_nw!(data_model))

    # add low level component types if not present yet
    for comp_type in ["load", "generator", "bus", "line", "shunt", "transformer_2wa", "storage", "switch"]
        if !haskey(data_model, comp_type)
            data_model[comp_type] = Dict{String, Any}()
        end
    end
    return data_model
end


function _expand_linecode!(data_model)
    # expand line codes
    for (id, line) in data_model["line"]
        if haskey(line, "linecode")
            linecode = data_model["linecode"][line["linecode"]]
            for key in ["rs", "xs", "g_fr", "g_to", "b_fr", "b_to"]
                line[key] = line["length"]*linecode[key]
            end
            delete!(line, "linecode")
            delete!(line, "length")
        end
    end
    delete!(data_model, "linecode")
end


function _load_to_shunt!(data_model)
    mappings = []
    if haskey(data_model, "load")
        for (id, load) in data_model["load"]
            if load["model"]=="constant_impedance"
                b = load["qd_ref"]./load["vnom"].^2*1E3
                g = load["pd_ref"]./load["vnom"].^2*1E3
                y = b.+im*g
                N = length(b)

                if load["configuration"]=="delta"
                    # create delta transformation matrix Md
                    Md = LinearAlgebra.diagm(0=>ones(N), 1=>-ones(N-1))
                    Md[N,1] = -1
                    Y = Md'*LinearAlgebra.diagm(0=>y)*Md

                else # load["configuration"]=="wye"
                    Y_fr = LinearAlgebra.diagm(0=>y)
                    # B = [[b]; -1'*[b]]*[I -1]
                    Y = vcat(Y_fr, -ones(N)'*Y_fr)*hcat(LinearAlgebra.diagm(0=>ones(N)),  -ones(N))
                end

                shunt = create_shunt(NaN, load["bus"], load["connections"], b_sh=imag.(Y), g_sh=real.(Y))
                add_component!(data_model, "shunt", shunt)
                delete_component!(data_model, "load", load)

                push!(mappings, Dict(
                    "load" => load,
                    "shunt" => shunt,
                ))
            end
        end
    end

    return mappings
end


function _capacitor_to_shunt!(data_model)
    mappings = []

    if haskey(data_model, "capacitor")
        for (id, cap) in data_model["capacitor"]
            b = cap["qd_ref"]./cap["vnom"]^2*1E3
            N = length(b)

            if cap["configuration"]=="delta"
                # create delta transformation matrix Md
                Md = LinearAlgebra.diagm(0=>ones(N), 1=>-ones(N-1))
                Md[N,1] = -1
                B = Md'*LinearAlgebra.diagm(0=>b)*Md

            elseif cap["configuration"]=="wye-grounded"
                B = LinearAlgebra.diagm(0=>b)

            elseif cap["configuration"]=="wye-floating"
                # this is a floating wye-segment
                # B = [b]*(I-1/(b'*1)*[b';...;b'])
                B = LinearAlgebra.diagm(0=>b)*(LinearAlgebra.diagm(0=>ones(N)) - 1/sum(b)*repeat(b',N,1))

            else # cap["configuration"]=="wye"
                B_fr = LinearAlgebra.diagm(0=>b)
                # B = [[b]; -1'*[b]]*[I -1]
                B = vcat(B_fr, -ones(N)'*B_fr)*hcat(LinearAlgebra.diagm(0=>ones(N)),  -ones(N))
            end

            shunt = create_shunt(NaN, cap["bus"], cap["connections"], b_sh=B)
            add_component!(data_model, "shunt", shunt)
            delete_component!(data_model, "capacitor", cap)

            push!(mappings, Dict(
                "capacitor" => cap,
                "shunt" => shunt,
            ))
        end
    end

    return mappings
end


# test
"""

    function decompose_transformer_nw_lossy!(data_model)

Replaces complex transformers with a composition of ideal transformers and lines
which model losses. New buses (virtual, no physical meaning) are added.
"""
function _decompose_transformer_nw!(data_model)
    mappings = []

    if haskey(data_model, "transformer_nw")
        for (tr_id, trans) in data_model["transformer_nw"]

            vnom = trans["vnom"]*data_model["v_var_scalar"]
            snom = trans["snom"]*data_model["v_var_scalar"]

            nrw = length(trans["bus"])

            # calculate zbase in which the data is specified, and convert to SI
            zbase = (vnom.^2)./snom
            # x_sc is specified with respect to first winding
            x_sc = trans["xsc"].*zbase[1]
            # rs is specified with respect to each winding
            r_s = trans["rs"].*zbase

            g_sh = (trans["noloadloss"]*snom[1]/3)/vnom[1]^2
            b_sh = (trans["imag"]*snom[1]/3)/vnom[1]^2

            # data is measured externally, but we now refer it to the internal side
            ratios = vnom/1E3
            x_sc = x_sc./ratios[1]^2
            r_s = r_s./ratios.^2
            g_sh = g_sh*ratios[1]^2
            b_sh = b_sh*ratios[1]^2

            # convert x_sc from list of upper triangle elements to an explicit dict
            y_sh = g_sh + im*b_sh
            z_sc = Dict([(key, im*x_sc[i]) for (i,key) in enumerate([(i,j) for i in 1:nrw for j in i+1:nrw])])

            vbuses, vlines, trans_t_bus_w = _build_loss_model!(data_model, r_s, z_sc, y_sh)

            trans_w = Array{Dict, 1}(undef, nrw)
            for w in 1:nrw
                # 2-WINDING TRANSFORMER
                # make virtual bus and mark it for reduction
                tm_nom = trans["configuration"][w]=="delta" ? trans["vnom"][w]*sqrt(3) : trans["vnom"][w]
                trans_w[w] = Dict(
                    "f_bus"         => trans["bus"][w],
                    "t_bus"         => trans_t_bus_w[w],
                    "tm_nom"        => tm_nom,
                    "f_connections" => trans["connections"][w],
                    "t_connections" => collect(1:4),
                    "configuration" => trans["configuration"][w],
                    "polarity"      => trans["polarity"][w],
                    "tm"            => trans["tm"][w],
                    "tm_fix"        => trans["tm_fix"][w],
                    "tm_max"        => trans["tm_max"][w],
                    "tm_min"        => trans["tm_min"][w],
                    "tm_step"       => trans["tm_step"][w],
                )

                add_virtual_get_id!(data_model, "transformer_2wa", trans_w[w])
            end

            delete_component!(data_model, "transformer_nw", trans)

            push!(mappings, Dict(
                "trans"=>trans,
                "trans_w"=>trans_w,
                "vlines"=>vlines,
                "vbuses"=>vbuses,
            ))
        end
    end

    return mappings
end


"""
Converts a set of short-circuit tests to an equivalent reactance network.
Reference:
R. C. Dugan, “A perspective on transformer modeling for distribution system analysis,”
in 2003 IEEE Power Engineering Society General Meeting (IEEE Cat. No.03CH37491), 2003, vol. 1, pp. 114-119 Vol. 1.
"""
function _sc2br_impedance(Zsc)
    N = maximum([maximum(k) for k in keys(Zsc)])
    # check whether no keys are missing
    # Zsc should contain tupples for upper triangle of NxN
    for i in 1:N
        for j in i+1:N
            if !haskey(Zsc, (i,j))
                if haskey(Zsc, (j,i))
                    # Zsc is symmetric; use value of lower triangle if defined
                    Zsc[(i,j)] =  Zsc[(j,i)]
                else
                    Memento.error(_LOGGER, "Short-circuit impedance between winding $i and $j is missing.")
                end
            end
        end
    end
    # make Zb
    Zb = zeros(Complex{Float64}, N-1,N-1)
    for i in 1:N-1
        Zb[i,i] = Zsc[(1,i+1)]
    end
    for i in 1:N-1
        for j in 1:i-1
            Zb[i,j] = (Zb[i,i]+Zb[j,j]-Zsc[(j+1,i+1)])/2
            Zb[j,i] = Zb[i,j]
        end
    end
    # get Ybus
    Y = LinearAlgebra.pinv(Zb)
    Y = [-Y*ones(N-1) Y]
    Y = [-ones(1,N-1)*Y; Y]
    # extract elements
    Zbr = Dict()
    for k in keys(Zsc)
        Zbr[k] = (abs(Y[k...])==0) ? Inf : -1/Y[k...]
    end
    return Zbr
end


function _build_loss_model!(data_model, r_s, zsc, ysh; n_phases=3)
    # precompute the minimal set of buses and lines
    N = length(r_s)
    tr_t_bus = collect(1:N)
    buses = Set(1:2*N)
    edges = [[[i,i+N] for i in 1:N]..., [[i+N,j+N] for (i,j) in keys(zsc)]...]
    lines = Dict(enumerate(edges))
    z = Dict(enumerate([r_s..., values(zsc)...]))
    shunts = Dict(2=>ysh)

    # remove Inf lines

    for (l,edge) in lines
        if real(z[l])==Inf || imag(z[l])==Inf
            delete!(lines, l)
            delete!(z, l)
        end
    end

    # merge short circuits

    stack = Set(keys(lines))

    while !isempty(stack)
        l = pop!(stack)
        if z[l] == 0
            (i,j) = lines[l]
            # remove line
            delete!(lines, l)
            # remove  bus j
            delete!(buses, j)
            # update lines
            for (k,(edge)) in lines
                if edge[1]==j
                    edge[1] = i
                end
                if edge[2]==j
                    edge[2] = i
                end
                if edge[1]==edge[2]
                    delete!(lines, k)
                    delete!(stack, k)
                end
            end
            # move shunts
            if haskey(shunts, j)
                if haskey(shunts, i)
                    shunts[i] += shunts[j]
                else
                    shunts[i] = shunts[j]
                end
            end
            # update transformer buses
            for w in 1:N
                if tr_t_bus[w]==j
                    tr_t_bus[w] = i
                end
            end
        end
    end

    bus_ids = Dict()
    for bus in buses
        bus_ids[bus] = add_virtual_get_id!(data_model, "bus", create_bus(""))
    end
    line_ids = Dict()
    for (l,(i,j)) in lines
        # merge the shunts into the shunts of the pi model of the line
        g_fr = b_fr = g_to = b_to = 0
        if haskey(shunts, i)
            g_fr = real(shunts[i])
            b_fr = imag(shunts[i])
            delete!(shunts, i)
        end
        if haskey(shunts, j)
            g_fr = real(shunts[j])
            b_fr = imag(shunts[j])
            delete!(shunts, j)
        end
        line_ids[l] = add_virtual_get_id!(data_model, "line", Dict(
            "status"=>1,
            "f_bus"=>bus_ids[i], "t_bus"=>bus_ids[j],
            "f_connections"=>collect(1:n_phases),
            "t_connections"=>collect(1:n_phases),
            "rs"=>LinearAlgebra.diagm(0=>fill(real(z[l]), n_phases)),
            "xs"=>LinearAlgebra.diagm(0=>fill(imag(z[l]), n_phases)),
            "g_fr"=>LinearAlgebra.diagm(0=>fill(g_fr, n_phases)),
            "b_fr"=>LinearAlgebra.diagm(0=>fill(b_fr, n_phases)),
            "g_to"=>LinearAlgebra.diagm(0=>fill(g_to, n_phases)),
            "b_to"=>LinearAlgebra.diagm(0=>fill(b_to, n_phases)),
        ))
    end

    return bus_ids, line_ids, [bus_ids[bus] for bus in tr_t_bus]
end

function make_compatible_v8!(data_model)
    data_model["conductors"] = 3
    for (_, bus) in data_model["bus"]
        bus["bus_type"] = 1
        bus["status"] = 1
        bus["bus_i"] = bus["index"]
        bus["vmin"] = fill(0.9, 3)
        bus["vmax"] = fill(1.1, 3)
    end

    for (_, load) in data_model["load"]
        load["load_bus"] = load["bus"]
    end

    data_model["gen"] = data_model["generator"]

    for (_, gen) in data_model["gen"]
        gen["gen_status"] = gen["status"]
        gen["gen_bus"] = gen["bus"]
        gen["pmin"] = gen["pg_min"]
        gen["pmax"] = gen["pg_max"]
        gen["qmin"] = gen["qg_min"]
        gen["qmax"] = gen["qg_max"]
        gen["conn"] = gen["configuration"]
        gen["cost"] = [1.0, 0]
        gen["model"] = 2
    end

    data_model["branch"] = data_model["line"]
    for (_, br) in data_model["branch"]
        br["br_status"] = br["status"]
        br["br_r"] = br["rs"]
        br["br_x"] = br["xs"]
        br["tap"] = 1.0
        br["shift"] = 0
        @show br
        if !haskey(br, "angmin")
            N = size(br["br_r"])[1]
            br["angmin"] = fill(-pi/2, N)
            br["angmax"] = fill(pi/2, N)
        end
    end

    for (_, tr) in data_model["transformer_2wa"]
        tr["rate_a"] = fill(1000.0, 3)
    end

    data_model["dcline"] = Dict()
    data_model["transformer"] = data_model["transformer_2wa"]

    data_model["per_unit"] = true
    data_model["baseMVA"] = 1E12
    data_model["name"] = "IDC"


    return data_model
end

# MAP SOLUTION UP

function map_solution_up(data_model::Dict, solution::Dict)
    sol_hl = deepcopy(solution)
    for i in length(data_model["mappings"]):-1:1
        (name, data) = data_model["mappings"][i]
        if name=="decompose_transformer_nw"
            @show data
        end
    end
end