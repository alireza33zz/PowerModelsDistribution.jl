"""
"""
function create_dss_object(::Type{T}, property_pairs::Vector{Pair{String,String}}, dss::OpenDssDataModel, dss_raw::OpenDssRawDataModel)::T where T <: DssLine
    raw_fields = collect(x.first for x in property_pairs)

    line = _apply_property_pairs(T(), property_pairs, dss, dss_raw)

    if :b1 ∈ raw_fields
        line.c1 = line.b1 / (2 * pi * line.basefreq)
    else
        line.b1 = line.c1 * (2 * pi * line.basefreq)
    end

    if line.phases == 1
        line.r0 = line.r1
        line.x0 = line.x1
        line.c0 = line.c1
        line.b0 = line.b1
    else
        if :b0 ∈ raw_fields
            line.c0 = line.b0 / (2 * pi * line.basefreq)
        else
            line.b0 = line.c0 * (2 * pi * line.basefreq)
        end
    end

    Zs = (complex(line.r1, line.x1) * 2.0 + complex(line.r0, line.x0)) / 3.0
    Zm = (complex(line.r0, line.x0) - complex(line.r1, line.x1)) / 3.0

    Ys = (complex(0.0, 2 * pi * line.basefreq * line.c1) * 2.0 + complex(0.0, 2 * pi * line.basefreq * line.c0)) / 3.0
    Ym = (complex(0.0, 2 * pi * line.basefreq * line.c0) - complex(0.0, 2 * pi * line.basefreq * line.c1)) / 3.0

    Z  = Matrix{Complex{Float64}}(undef, line.phases, line.phases)
    Yc = Matrix{Complex{Float64}}(undef, line.phases, line.phases)
    for i in 1:line.phases
        Z[i,i] = Zs
        Yc[i,i] = Ys
        for j in 1:i-1
            Z[i,j] = Z[j,i] = Zm
            Yc[i,j] = Yc[j,i] = Ym
        end
    end

    line.rmatrix = :rmatrix ∈ raw_fields ? line.rmatrix : real(Z)
    line.xmatrix = :xmatrix ∈ raw_fields ? line.xmatrix : imag(Z)
    line.cmatrix = :cmatrix ∈ raw_fields ? line.cmatrix : imag(Yc) / (2 * pi * line.basefreq)

    # TODO: support length mismatch between line and linecode?
    # Currently this does not change the values of rmatrix and xmatrix due to
    # lenmult=1, code is only in place for future use.
    lenmult = 1.0

    circuit_basefreq = getproperty(dss.options, :basefrequency)

    kxg = line.xg / log(658.5 * sqrt(line.rho / circuit_basefreq))
    xgmod = line.xg != 0.0 ?  0.5 * kxg * log(line.basefreq / circuit_basefreq) : 0.0

    units = line.units
    len = line.switch ? 0.001 : line.length * _convert_to_meters[units]

    line.rmatrix .+= line.rg * (line.basefreq / circuit_basefreq - 1.0)
    line.rmatrix .*= lenmult
    line.xmatrix .-= xgmod
    line.xmatrix .*= lenmult * (line.basefreq / circuit_basefreq)


    line.r1 = line.r1 / _convert_to_meters[line.units]
    line.x1 = line.x1 / _convert_to_meters[line.units]
    line.r0 = line.r0 / _convert_to_meters[line.units]
    line.x0 = line.x0 / _convert_to_meters[line.units]
    line.c1 = line.c1 / _convert_to_meters[line.units]
    line.c0 = line.c0 / _convert_to_meters[line.units]
    line.rmatrix = line.rmatrix / _convert_to_meters[line.units]
    line.xmatrix = line.xmatrix / _convert_to_meters[line.units]
    line.cmatrix = line.cmatrix / _convert_to_meters[line.units]
    line.b1 = line.b1 / _convert_to_meters[line.units]
    line.b0 = line.b0 / _convert_to_meters[line.units]
    line.units = "m"

    return line
end


"""
"""
function create_dss_object(::Type{T}, property_pairs::Vector{Pair{String,String}}, dss::OpenDssDataModel, dss_raw::OpenDssRawDataModel)::T where T <: DssVsource
    raw_fields = collect(x.first for x in property_pairs)

    vsource = _apply_property_pairs(T(), property_pairs, dss, dss_raw)

    rs = 0.0
    rm = 0.0
    xs = 0.1
    xm = 0.0

    factor = vsource.phases == 1 ? 1.0 : sqrt(3.0)

    r2 = vsource.r1
    x2 = vsource.x1

    Zbase = vsource.basekv^2 / vsource.basemva
    ∈
    if (:mvasc3 ∈ raw_fields || :mvasc1 ∈ raw_fields) || (:isc3 ∈ raw_fields || :isc1 ∈ raw_fields)
        if :mvasc3 ∈ raw_fields || :mvasc1 ∈ raw_fields
            vsource.isc3 = :mvasc3 ∈ raw_fields ? vsource.mvasc3 * 1e3 / (vsource.basekv * sqrt(3.0)) : vsource.isc3
            vsource.isc1 = :mvasc1 ∈ raw_fields ? vsource.mvasc1 * 1e3 / (vsource.basekv * factor) : vsource.isc1
        elseif :isc3 ∈ raw_fields || :isc1 ∈ raw_fields
            vsource.mvasc3 = :isc3 ∈ raw_fields ? sqrt(3) * vsource.basekv * vsource.isc3 / 1e3 : vsource.mvasc3
            vsource.mvasc1 = :isc1 ∈ raw_fields ? factor * vsource.basekv * vsource.isc1 / 1e3 : vsource.mvasc1
        end

        vsource.x1 = vsource.basekv^2 / vsource.mvasc3 / sqrt(1.0 + 1.0 / vsource.x1r1^2)

        vsource.r1 = vsource.x1 / vsource.x1r1
        r2 = vsource.r1
        x2 = vsource.x1

        a = 1.0 + vsource.x0r0^2
        b = 4.0*(vsource.r1 + vsource.x1 * vsource.x0r0)
        c = 4.0 * (vsource.r1^2 + vsource.x1^2)- (3.0 * vsource.basekv * 1000.0 / factor / vsource.isc1)^2
        vsource.r0 = max((-b + sqrt(b^2 - 4 * a * c)) / (2 * a), (-b - sqrt(b^2 - 4 * a * c)) / (2 * a))
        vsource.x0 = vsource.r0 * vsource.x0r0

        xs = (2.0 * vsource.x1 + vsource.x0) / 3.0
        rs = (2.0 * vsource.r1 + vsource.r0) / 3.0

        rm = (vsource.r0 - vsource.r1) / 3.0
        xm = (vsource.x0 - vsource.x1) / 3.0
    elseif any([key ∈ raw_fields for key in [:r1, :x1, :z1, :puz1]])
        if :puz1 ∈ raw_fields
            puz1 = complex(vsource.puz1...)
            puz2 = complex(vsource.puz2...)
            puz0 = complex(vsource.puz0...)

            vsource.r1 = real(vsource.puz1) * Zbase
            vsource.x1 = imag(puz1) * Zbase
            r2 = real(puz2) * Zbase
            x2 = imag(puz2) * Zbase
            vsource.r0 = real(puz0) * Zbase
            vsource.x1 = imag(puz0) * Zbase
        elseif (:r1 ∈ raw_fields && :x1 ∈ raw_fields)
            r2 = vsource.r1
            x2 = vsource.x1
        elseif :z1 ∈ raw_fields
            z1 = complex(vsource.z1...)
            z2 = complex(vsource.z2...)
            z0 = complex(vsource.z0...)

            vsource.r1 = real(z1)
            vsource.x1 = imag(z1)
            r2 = real(z2)
            x2 = imag(z2)
            vsource.r0 = real(z0)
            vsource.x0 = imag(z0)
        end

        vsource.isc3 = vsource.basekv * 1e3 / sqrt(3.0) * abs(complex(vsource.r1, vsource.x1))

        if vsource.phases == 1
            vsource.r0 = vsource.r1
            vsource.x0 = vsource.x1
            r2 = vsource.r1
            x2 = vsource.x1
        end

        rs = (2.0 * vsource.r1 + vsource.r0) / 3.0
        xs = (2.0 * vsource.x1 + vsource.x0) / 3.0

        rm = (vsource.r0 - vsource.r1) / 3.0
        xm = xs - vsource.x1

        vsource.isc1 = vsource.basekv * 1e3 / factor / abs(complex(rs, xs))

        vsource.mvasc3 = sqrt(3) * vsource.basekv * vsource.isc3 / 1e3
        vsource.mvasc1 = factor * vsource.basekv * vsource.isc1 / 1e3
    else
        rs = (2.0 * vsource.r1 + vsource.r0) / 3.0
        xs = (2.0 * vsource.x1 + vsource.x0) / 3.0

        rm = (vsource.r0 - vsource.r1) / 3.0
        xm = (vsource.x0 - vsource.x1) / 3.0
    end

    Z = zeros(Complex{Float64}, vsource.phases, vsource.phases)
    if vsource.r1 == r2 && vsource.x1 == x2
        Zs = complex(rs, xs)
        Zm = complex(rm, xm)

        for i in 1:vsource.phases
            Z[i,i] = Zs
            for j in 1:i-1
                Z[i, j] = Z[j, i] = Zm
            end
        end
    else
        z1 = complex(vsource.r1, vsource.x1)
        z2 = complex(r2, x2)
        z0 = complex(vsource.r0, vsource.x0)

        for i in 1:vsource.phases
            Z[i,i] = (z1 + z2 + z0) / 3.0
        end

        if vsource.phases == 3
            Z[2, 1] = Z[3, 2] = Z[1, 3] = (conj(exp(-2*pi*im/3))^2 * z2 + conj(exp(-2*pi*im/3)) * z1 + z0) / 3
            Z[3, 1] = Z[1, 2] = Z[2, 3] = (conj(exp(-2*pi*im/3))^2 * z1 + conj(exp(-2*pi*im/3)) * z2 + z0) / 3
        end
    end

    vsource.vmag = vsource.phases == 1 ? vsource.basekv * vsource.pu * 1e3 : vsource.basekv * vsource.pu * 1e3 / 2 / sin(pi / vsource.phases)

    if :puz1 ∉ raw_fields && Zbase > 0.0
        vsource.puz1 = Float64[vsource.r1 / Zbase, vsource.x1 / Zbase]
        vsource.puz2 = Float64[r2 / Zbase, x2 / Zbase]
        vsource.puz0 = Float64[vsource.r0 / Zbase, vsource.x0 / Zbase]
    end

    vsource.rmatrix = real(Z)
    vsource.xmatrix = imag(Z)

    return vsource
end


"""
"""
function create_dss_object(::Type{T}, property_pairs::Vector{Pair{String,String}}, dss::OpenDssDataModel, dss_raw::OpenDssRawDataModel)::T where T <: DssCapacitor
    raw_fields = collect(x.first for x in property_pairs)

    capacitor = _apply_property_pairs(T(), property_pairs, dss, dss_raw)

    capacitor.bus2 = :bus2 ∉ raw_fields ? string(split(capacitor.bus1, ".")[1],".",join(fill("0", capacitor.phases), ".")) : capacitor.bus2

    return capacitor
end


"""
"""
function create_dss_object(::Type{T}, property_pairs::Vector{Pair{String,String}}, dss::OpenDssDataModel, dss_raw::OpenDssRawDataModel)::T where T <: DssTransformer
    raw_fields = collect(x.first for x in property_pairs)

    transformer = _apply_property_pairs(T(), property_pairs, dss, dss_raw)

    return transformer
end


"""
"""
function create_dss_object(::Type{T}, property_pairs::Vector{Pair{String,String}}, dss::OpenDssDataModel, dss_raw::OpenDssRawDataModel)::T where T <: DssReactor
    raw_fields = collect(x.first for x in property_pairs)

    reactor = _apply_property_pairs(T(), property_pairs, dss, dss_raw)

    if :basefreq ∉ raw_fields
        reactor.basefreq = dss.options.defaultbasefrequency
    end

    # TODO: handle `parallel`
    if (:kv ∈ raw_fields && :kvar ∈ raw_fields) || :x ∈ raw_fields || :lmh ∈ raw_fields || :z ∈ raw_fields
        if :kvar ∈ raw_fields && :kv ∈ raw_fields
            kvarperphase = reactor.kvar / reactor.phases
            if reactor.conn == DELTA
                phasekv = reactor.kv
            else
                if reactor.phases == 2 || reactor.phases == 3
                    phasekv = reactor.kv / sqrt(3.0)
                else
                    phasekv = reactor.kv
                end
            end

            reactor.x = phasekv^2 * 1.0e3 / kvarperphase
            reactor.l = reactor.x / (2 * pi) / reactor.basefreq
            reactor.lmh = reactor.l * 1e3
            reactor.normamps = kvarperphase / phasekv
            reactor.emergamps = reactor.normamps * 1.35

        elseif :x ∈ raw_fields
            reactor.l = reactor.x / (2 * pi) / reactor.basefreq
            reactor.lmh = reactor.l * 1e3

        elseif :lmh ∈ raw_fields
            reactor.l = reactor.lmh / 1.0e3
            reactor.x = reactor.l * 2 * pi * reactor.basefreq

        elseif :z ∈ raw_fields
            z = complex(reactor.z...)
            reactor.r = real(z)
            reactor.x = imag(z)
            reactor.l = reactor.x / (2 * pi) / reactor.basefreq
            lmh = reactor.l * 1e3
        end

        rmatrix = LinearAlgebra.diagm(0 => fill(reactor.r, reactor.phases))
        xmatrix = LinearAlgebra.diagm(0 => fill(reactor.x, reactor.phases))
    elseif :rmatrix ∈ raw_fields && :xmatrix ∈ raw_fields
        reactor.r = reactor.rmatrix[1, 1]
        reactor.x = reactor.xmatrix[1, 1]

        # TODO: account for off-diagonal and single phase
        reactor.z = reactor.z1 = reactor.z2 = reactor.z0 = [reactor.r, reactor.x]
        reactor.lmh = reactor.x / (2 * pi) / reactor.basefreq * 1e3
    elseif :z1 ∈ raw_fields
        z1 = complex(reactor.z1...)
        z2 = complex(reactor.z2...)
        z0 = complex(reactor.z0...)

        Z = zeros(Complex{Float64}, reactor.phases, reactor.phases)

        for i in 1:reactor.phases
            if reactor.phases == 1
                Z[i,i] = complex(z1...) / 3.0
            else
                Z[i,i] = (complex(z2...) + complex(z1...) + complex(z0...)) / 3.0
            end
        end

        if reactor.phases == 3
            Z[2, 1] = Z[3, 2] = Z[1, 3] = (conj(exp(-2*pi*im/3))^2 * z2 + conj(exp(-2*pi*im/3)) * z1 + z0) / 3
            Z[3, 1] = Z[1, 2] = Z[2, 3] = (conj(exp(-2*pi*im/3))^2 * z1 + conj(exp(-2*pi*im/3)) * z2 + z0) / 3
        end

        reactor.rmatrix = real(Z)
        reactor.xmatrix = imag(Z)

        reactor.r = rmatrix[1,1]
        reactor.x = xmatrix[1,1]
        reactor.lmh = reactor.x / (2 * pi * reactor.basefreq) * 1e3
    else
        reactor.rmatrix = LinearAlgebra.diagm(0 => fill(reactor.r, reactor.phases))
        reactor.xmatrix = LinearAlgebra.diagm(0 => fill(reactor.x, reactor.phases))
    end

    return reactor
end