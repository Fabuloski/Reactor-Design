### A Pluto.jl notebook ###
# v0.19.22

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ 5ecc9a90-acc7-11ed-1233-43da78353190
using Optim, DataFrames, CSV, ColorSchemes, PlutoUI, CairoMakie, DiffEqOperators, ModelingToolkit, DifferentialEquations, DomainSets, MethodOfLines, ScikitLearn

# ╔═╡ f922a709-b553-4888-99e4-1795056cfa46
using Roots

# ╔═╡ f922a709-b553-4888-99e4-1795056cfa46
using Roots

# ╔═╡ 73956355-f662-4d50-bb07-f4ffbd91f99f
begin
	PlumeModel = include("src/PlumeModel.jl")
end

# ╔═╡ b456ab98-c614-45ca-92a8-4a63634c4991
@sk_import linear_model: LinearRegression

# ╔═╡ 352b723f-c67e-4a2a-b53d-b131fc5debbc
colors = ColorSchemes.tab10

# ╔═╡ e2444136-3e5a-4be6-b81b-0c8b330b50e5
TableOfContents()

# ╔═╡ b0159335-af41-4523-89c1-07dbff30c298
md"""
# Catalyst Packed Bed Reactor.
"""

# ╔═╡ ba885028-fc4c-4605-adca-97b0bc063901
md"""
## Setting up the PDE
"""

# ╔═╡ 0f13982d-26a5-43a1-bba1-6e3e3659277a
md"
# setting up plume advection diffusion reaction

##### reaction:
$A_g + S \rightleftharpoons A_{ad}$
*  $A      :=$ some gas analyte
*  $A_g    :=$ unadsorbed gas molecule
*  $S      :=$ adsorption site
*  $A_{ad} :=$ adsorbed gas molecule

##### Langmuir adsorption equation:

$\textbf{n(p)} = \theta_A = \frac{V}{V_m} = \frac{K_{eq}p_{A}}{1 + K_{eq}p_{A}}$

*  $\theta_A :=$ the fractional occupancy of the adsorption sites
*  $p_A :=$
*  $n(p) :=$ the amount of gas adsorbed inside the MOF
*  $K_{eq} :=$ adsorption equilibrium constant
*  $\frac{V}{V_m} :=$ the ratio of the volume of gas adosrbed onto the solid (V) to the volume of a monolayer of gas molecules covering the surface of the solid.

### Defining our system
##### (non competitive):


*  $\Delta x$ = $(@bind Δx confirm(NumberField(0.5:1.0, default=1.0)))
*  $x$ length = $(@bind ℓ confirm(NumberField(5.0:50.0, default=10.0)))
*  $\Delta t$ = $(@bind Δt confirm(NumberField(0.2:1.0)))
*  Diffusivity = $(@bind diff confirm(NumberField(0.0:5.0, default=1.0)))
*  Wind Strength = $(@bind wind confirm(NumberField(10.0:20.0, default=10.0)))
*  reaction rate (plume decay) = $(@bind rₐ_plume confirm(NumberField(0.5:2.0, default=0.5)))
*  source decay = $(@bind breath confirm(NumberField(0.17:2.0, default=0.17)))
*  source size = $(@bind srce confirm(NumberField(0.5:1.0, default=0.5)))
*  $C_{bulk}$ = $(@bind c_bulk confirm(NumberField(1.1:100.0, default=1.1)))

"
#*  $K$ = $(@bind k confirm(NumberField(0.0:100.0, default=1.0)))

# ╔═╡ 95a86945-9001-4dc4-85b0-336259c30929
md"""
### magic numbers

* source decay ~ 0.17 (runs out of breath around 15 seconds)
* source size ~ 0.5 (sufficient starting concentration to maintain consistent conc)
* wind str ~ 10.0 (seems to provide decent breath velocity)
"""

# ╔═╡ 093a6227-734f-4ac6-b0c0-f676f2d1eb67
function plume_pde(; wind_str::Float64=-1.0, 
                            diffusivity::Float64=1.0, 
                            plume_decay::Float64=0.0,
                            source_decay::Float64=0.5,
                            Δt::Float64=0.2,
                            t_end::Float64=26.0,
                            Δx₁::Float64=0.1,	
                            Δx₂::Float64=1.0,
                            x₁_max::Float64=10.0,
                            x₂_max::Float64=10.0,
                            source_size::Float64=0.2,
							C_bulk::Float64=1.0)
	@parameters  x₁ x₂ t 
	@variables c(..) s(..)

	∂t  = Differential(t)
	∂x₁  = Differential(x₁)
	∂x₂  = Differential(x₂)
	∂²x₁ = Differential(x₁) ^ 2
	∂²x₂ = Differential(x₂) ^ 2
	U = wind_str
	D = diffusivity
	ℓ₁ = x₁_max
	ℓ₂ = x₂_max
	λ₁ = plume_decay #plume decay
	λ₂ = source_decay #source decay
	c_point = C_bulk #arbitrary, controls initial concentration value

	"""
	Hacks the domain of the initial condition to allow for a point source located at the shared mean.
	"""
	function gaussian_hack(x₁; 
							μ₁::Float64 = 0.0,
							σ::Float64 = 0.1)
		return exp(-((x₁-μ₁)/σ)^2.0)*c_point
	end

	function s(x₁,
		t; 
		μ₁::Float64 = 0.0,
		σ::Float64 = 0.1)
		#function of t ime and space, continuous source
		#=
		if (x₁ < ℓ₁/2 - source_size/2) && (x₁ > ℓ₁/2 + source_size/2)
			if (x₂ < ℓ₂/2 - source_size/2) && (x₂ > ℓ₂/2 + source_size/2)
				return c_point*exp(-λ₂*t)
			end
		end
		=#
		return exp(-((x₁-μ₁)/σ)^2.0)*c_point*exp(-λ₂*(t-1))
	end


	diff_eq = [∂t(c(x₁, x₂, t)) ~ D*∂²x₁(c(x₁, x₂, t)) + D*∂²x₂(c(x₁, x₂, t))  + U*∂x₁(c(x₁, x₂, t)) - λ₁*c(x₁, x₂, t) + s(x₁, t, σ=source_size)]

	bcs = [
	#initial condition
		c(x₁, x₂, 0) ~ c_point * gaussian_hack(x₁, σ=source_size),
	#bc's
		∂x₁(c(ℓ₁, x₂, t)) ~ 0.0,
		∂x₁(c(0.0, x₂, t)) ~ 0.0,
		#∂x₂(c(x₁, ℓ₂, t)) ~ 0.0,
		#∂x₂(c(x₁, 0.0, t)) ~ 0.0
		c(x₁, ℓ₂, t) ~ 0.0,
		c(x₁, 0.0, t) ~ 0.0]


	# define space-time plane 
	domains = [x₁ ∈ Interval{:closed, :closed}(0.0, ℓ₁),
			   x₂ ∈ Interval{:closed, :closed}(0.0, ℓ₂), 
			   t ∈ Interval{:closed, :closed}(0.0, t_end), 
			   c(x₁, x₂, t) ∈ Interval{:closed, :closed}(0.0, c_point)]

	# put it all together into a PDE system
	@named pdesys = PDESystem(diff_eq, bcs, domains, [x₁, x₂, t], [c(x₁, x₂, t)]);

	# discretize space [x₁=>Δx₁, x₂=>Δx₂]
	discretization = MOLFiniteDifference([x₁=>Δx₁, x₂=>Δx₂], t)

	# convert the PDE into a system of ODEs via method of lines
	prob = discretize(pdesys, discretization)

	# solve system of ODEs in time.
	sol           = solve(prob, saveat=Δt)
	solution_grid = sol[c(x₁, x₂, t)]

	return solution_grid
end

# ╔═╡ 0cb2b595-2ee6-44e8-81ce-2497352625b2
md"""
## Heatmap visuation plotting function
"""

# ╔═╡ 034129ed-c1a0-4fab-ba42-381fe227c0b0
begin
	function viz_heat_map(grid::Array{Float64, 3}; 
                        time_stamp::Int=10, 
                        Δt::Float64=0.2, 
                        Δx₁::Float64=0.1,
                        Δx₂::Float64=1.0,
                        color_range=(minimum(grid[:, :, time_stamp]), 
                                     maximum(grid[:, :, time_stamp])))
        fig = Figure()
        ax = Axis(fig[1, 1], 
				  xlabel="x₁ [position]", 
				  ylabel="r [position]", 
				  yticks=([1.5, 6, 10.5], ["-R", "0", "R"]),
				  xlabelsize = 22, 
				  ylabelsize=22, 
				  title="time $(truncate(Δt * time_stamp - Δt, 2)) [s]")
        		  hm = gen_heat_map!(grid, 
					  				 ax, 
					  				 time_stamp=time_stamp, 
					  				 Δt=Δt, 
					  				 Δx₁=Δx₁,
					  			     Δx₂=Δx₂,
					  				 color_range=color_range)
        Colorbar(fig[1, 2], hm, label="ppm")
        return fig
    end

    function gen_heat_map!(grid::Array{Float64, 3},
			ax; 
			time_stamp::Int=10, 
			Δt::Float64=0.2, 
			Δx₁::Float64=0.1,
			Δx₂::Float64=1.0,
			color_range::Tuple{Float64, Float64}=(minimum(grid[:, :, time_stamp]), 
                                          		  maximum(grid[:, :, time_stamp])))
        x₁_dim = size(grid[:, :, :], 1)
        x₂_dim = size(grid[:, :, :], 2)
        x₁_coords = [Δx₁*i for i=1:x₁_dim]
        x₂_coords = [Δx₂*i for i=1:x₂_dim]
        hm = heatmap!(ax, 
					x₁_coords, 
					x₂_coords, 
					grid[:, :, time_stamp], 
					colorrange=color_range, 
					colormap=:nipy_spectral)
    end
	function truncate(n::Float64, digits::Int)
        n = n*(10^digits)
        n = trunc(Int, n)
        convert(AbstractFloat, n)
        return n/(10^digits)
    end
end

# ╔═╡ bce5bf5b-d943-4a05-a6c4-a00f2f296f57
plume_model = plume_pde(Δx₁=Δx, x₁_max=ℓ, Δt=Δt, diffusivity=diff, wind_str=-wind, plume_decay=rₐ_plume, source_decay=breath, source_size=srce, C_bulk=c_bulk)

# ╔═╡ b0db17f8-0ebe-4412-ab1c-3c5a62e4c786
viz_heat_map(plume_model, time_stamp=100, Δx₁=Δx, Δt=Δt, color_range=(0.0, 1.0))

# ╔═╡ 3755f3d2-a1bc-4519-8562-1415dcd57b21
md"""
## mp4 generating function for making a video of 2-D gas flow
"""

# ╔═╡ ab43c1ff-dff8-4b15-9b0d-f1938c78ed59
    function gen_video(grid::Array{Float64, 3}; 
                        Δt::Float64=0.2, 
                        n_frames::Int=130,
                        Δx₁::Float64=0.1,
                        Δx₂::Float64=1.0,
                        framerate::Int=1)
        fig = Figure()
        ax = Axis(fig[1, 1], xlabel="x₁ [position]", ylabel="r [position]", yticks=([1.5, 6, 10.5], ["-R", "0", "R"]), xlabelsize = 30, ylabelsize=30, title="time 0.0 [s]")

        color_range = (minimum(grid[:, :, :]), maximum(grid[:, :, :]))

        t_end = n_frames * Δt
        time_frame_iterator = [i for i=1:length(0.0:Δt:t_end)]

        #, color_range=(minimum(grid[:, :, :]), maximum(grid[:, :, :]))

        record(fig, 
        "plume_diffusion.mp4", 
        time_frame_iterator;
        framerate=framerate) do frame
        time_seconds = Δt * frame - Δt
        ax.title = "time $(truncate(time_seconds, 2)) [s]"
        hm = gen_heat_map!(grid, ax, Δx₁=Δx₁, Δx₂=Δx₂, time_stamp=frame, Δt=Δt, color_range=color_range)
            if frame==1
                Colorbar(fig[1, 2], hm, label="ppm")
            end
        end
    end

# ╔═╡ 33c569c3-7c98-49a9-b9dd-77ec56957111
gen_video(plume_model, framerate=2, Δx₁=Δx, Δt=Δt)

# ╔═╡ 8d5588b4-8eab-44ed-9921-d96b6f1bf21b
md"""
# Extracting Conversion Data
"""

# ╔═╡ eeedcd3e-72ea-48b8-88a6-3e9a6edb3a6d
analytes = ["acetone", "ethanol", "isoprene", "ammonia", "H2"]

# ╔═╡ dce8c693-36ff-4d37-9922-ebba0338602f
typeof(analytes)

# ╔═╡ b77cc6d2-7ff9-4fcc-9196-55a1912b2e67
function data_filename(name::String)
	return joinpath("data", name * ".csv")
end

# ╔═╡ 43d9317c-4206-41ef-ab7a-fadb73f5cc57
function conversion_data(name::String)
	filename = data_filename(name)
    data = CSV.read(filename, DataFrame, comment="#")

	#convert celcius column to kelvin
	data[:, "T (K)"] = data[:, "T (C)"] .+ 273.15
	data = data[:, ["T (K)", "X (%)"]]

	return data
end

# ╔═╡ 439d93ee-4a14-40e4-83d1-2508804cb79f
begin
	data = Dict()
	data["a"] = 1.0
end

# ╔═╡ dbc3182d-5b9e-4f41-b4e5-586b98f89fae
function conversion_data_lib(analytes::Vector{String})
	data = Dict()
	for gas in analytes
		data[gas] = conversion_data(gas)
	end

	return data
end

# ╔═╡ 239fd31b-84d1-4dca-98f0-4889a930e54d
data_dict = conversion_data_lib(analytes)

# ╔═╡ a5de549f-c300-426d-93c4-1b8e3df358f2
begin
	fig = Figure()
	temp_ideal = 135+273.13
	ax=Axis(fig[1,1], xlabel="Temp [K]", ylabel="X [%]")
	local colors=[:blue, :red, :green, :yellow, :purple]
	shapes=[:circle, :rect, :utriangle, :star5, :diamond]

	for (i, data) in enumerate(data_dict)
		lines!(data_dict[analytes[i]][:, "T (K)"], data_dict[analytes[i]][:, "X (%)"], color=colors[i])
		scatter!(data_dict[analytes[i]][:, "T (K)"], data_dict[analytes[i]][:, "X (%)"], label=analytes[i], markersize=20, color=colors[i], marker=shapes[i], strokewidth=1, strokecolor=:black)
	end
	lines!([temp_ideal, temp_ideal], [0.0, 100.0], color=:black, linewidth=3, label="Operation Temp")

	axislegend(position=:rb)

	fig
end

<<<<<<< HEAD
# ╔═╡ 7c56fa73-f7b8-4f21-8080-875d82c9e170
acetone_data = data_dict["acetone"]

# ╔═╡ 8b1e0bfd-19d0-497a-96aa-3f22b0565371
data_dict["acetone"]

=======
<<<<<<< HEAD
# ╔═╡ aaee7564-5417-4ece-a115-be412614ceba
=======
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59
# ╔═╡ 00c7ce53-3317-4265-bde6-b90364e96763
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
md"""
## Parameters
"""

<<<<<<< HEAD
# ╔═╡ ca188d5a-eb67-44c1-b6c0-ea4124b878bb
=======
<<<<<<< HEAD
# ╔═╡ 5a461d73-e6f9-4584-a2ac-962e68a8eb17
begin
	g = v₀ * 30 * 10 ^ -6
	p(k) = k * (0.09 - 0.09 ^ 2/2)
	f(k) = g - p(k)
	# k₀ = find_zeros(f, 0, 1000)[1]
end

# ╔═╡ 7c56fa73-f7b8-4f21-8080-875d82c9e170
acetone_data = data_dict["acetone"]

# ╔═╡ ca188d5a-eb67-44c1-b6c0-ea4124b878bb
begin
	Cₐ₀ = 1
	T₀ = 382.947
	k₀ = 10^3.55
	Ea = 75622
end

# ╔═╡ 2b3f63ed-24cc-42a7-a7a4-9136b91093fb
Ea

# ╔═╡ 80ef01e9-65d6-4668-a5a4-7d562b65234b
exp(0)

# ╔═╡ d49fa061-642f-434d-a3c7-de5d68d92eb9
begin
	kₐ(T; k₀=k₀, T₀=T₀, Ea=Ea) = k₀ * exp((Ea / 8.314) * ((1/T₀) -(1/T)))
	rₐ_pbr(T, X) = kₐ(T) * (1 - X)
end

# ╔═╡ b78e66a4-f891-4b3b-ad3a-3355dc58f5c7
function solve!(du, u, p, W)
X, T = u
Fₐ₀, ΔHᵣₙₓ, Ta₀ = p
du[1] = rₐ_pbr(T, X) / v₀
end

# ╔═╡ 8f9a55bd-0354-4e73-88e5-408792709a2b
Ea

# ╔═╡ ed404504-75ff-45f3-8aed-ebcc2be62ec1
T =292.953

# ╔═╡ 34936add-e8ad-4300-96e7-52016ea95a77
kₐ(T)

# ╔═╡ 7e8ae5f7-0d4f-46d2-a313-cfcdfb7e07a9
nrow(acetone_data)

# ╔═╡ 9756ded3-2f58-4463-a706-42cc5cb382ff
begin
	X = zeros(nrow(acetone_data))
	for (i, j) in enumerate(X) 
		Wspan= (10^-6, 30 * 10^-6)
		T = acetone_data[i, "T (K)"]
		prob = ODEProblem(solve!, [0, T], Wspan, [v₀, 0, 0])
		sol = solve(prob)
		X[i] = rename!(DataFrame(sol)[:, [1, 2]], "timestamp" => :Weight, "value1" => :X)[end, 2]
	end
	X = X .* 100
end

# ╔═╡ e2887f4b-ce36-45ef-9adc-074860aa2944
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Temperature [K]", ylabel="X")
	scatter!(acetone_data[:, "T (K)"], X)
	fig
end

# ╔═╡ 2a5d417b-6d8c-43ca-b143-3dc3c98903a9
@bind v₀ PlutoUI.Slider(1 : 10, default=2)

# ╔═╡ 22a9000e-79d2-42e0-9d5f-0fb703dc8fc5
# ╠═╡ disabled = true
#=╠═╡
v₀ = 2
=======
# ╔═╡ 7970cc8b-4feb-489c-a46b-c4e0ef175054
@bind Ea PlutoUI.Slider(5 * 10^0 : 5 * 10^6)

# ╔═╡ bd44687a-ae4c-4646-9ea7-f1dbacd5e37b
@bind Fₐ₀ PlutoUI.Slider(1 : 10)

# ╔═╡ 71280fbc-b054-4d10-b4a3-3579393a090c
Fₐ₀

# ╔═╡ 1081a6d9-c980-47bf-a117-73a574c4b287
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59
begin
	Cₐ₀ = 1
	Cᵢ₀ = 1
	T₀ = 382.947
	k₀ = 10^3.55
	Ea = 75622
end

# ╔═╡ 29a76bde-f13e-429a-83a0-6a2aa2e6d630
begin
	temp = [0.002981, 0.003116, 0.003179, 0.003269, 0.003332]
	lnk = [-1.38368, -2.33536, -2.80715, -3.66707, -4.14292]
end

# ╔═╡ dfb10f69-0b77-46f3-9f1e-ba94cdd6c131
algo = LinearRegression().fit(reshape(temp, (5, 1)), reshape(lnk, (5, 1)))

# ╔═╡ 35a219e8-800e-44a3-8f67-e77b148ab47b
Eaᵢ = -8.314 * -5364.2

# ╔═╡ 7b5b6f35-94d8-4647-a888-3b5bbe17f656
A = exp(26.356)

# ╔═╡ ea27a021-0ccc-4b5c-a049-fe285985d661
kᵢ(T) = A * exp(-Eaᵢ / (8.314 * T))

# ╔═╡ ae232c11-0447-4fa0-a889-87968b72da93
kᵢ(298)

# ╔═╡ 2a5d417b-6d8c-43ca-b143-3dc3c98903a9
@bind v₀ PlutoUI.Slider(1 : 10, default=2)

# ╔═╡ 5a461d73-e6f9-4584-a2ac-962e68a8eb17
begin
	g = v₀ * 30 * 10 ^ -6
	p(k) = k * (0.09 - 0.09 ^ 2/2)
	f(k) = g - p(k)
	# k₀ = find_zeros(f, 0, 1000)[1]
end

# ╔═╡ dfb407dc-f86a-4279-a85d-ff82c70beaeb
begin
	kₐ(T; k₀=k₀, T₀=T₀, Ea=Ea) = k₀ * exp(Ea / 8.314 * ((1/T₀) -(1/T)))
	rₐ(T, X) = kₐ(T) * Cₐ₀ * (1 - X)
	rᵢ(T, X) = kᵢ(T) * Cᵢ₀ * (1 - X)
end

# ╔═╡ b78e66a4-f891-4b3b-ad3a-3355dc58f5c7
function analyte!(du, u, p, W)
X, T = u
v₀, ΔHᵣₙₓ, Ta₀ = p
du[1] = rₐ(T, X) / v₀
end

# ╔═╡ 82e72ff5-d6e6-4ac5-beac-4eb3b0efe5ad
function interference!(du, u, p, W)
X, T = u
v₀, ΔHᵣₙₓ, Ta₀ = p
du[1] = rᵢ(T, X) / v₀
end

# ╔═╡ a3f63c04-a2ff-4b8a-8261-0d9ac195c1c9
Ts = collect(range(200, 600, length =50))

# ╔═╡ 9756ded3-2f58-4463-a706-42cc5cb382ff
function model(v₀, Ts; W=30 * 10^-6)
	X_analyte = zeros(length(Ts))
	X_interference = zeros(length(Ts))
	for (i, T) in enumerate(Ts) 
		Wspan= (0, W)
		# T = Ts[i]
		prob_a = ODEProblem(analyte!, [0, T], Wspan, [v₀, 0, 0])
		prob_i = ODEProblem(interference!, [0, T], Wspan, [v₀, 0, 0])
		sol_a = solve(prob_a)
		sol_i = solve(prob_i)
		X_analyte[i] = rename!(DataFrame(sol_a)[:, [1, 2]], "timestamp" => :Weight, "value1" => :X)[end, 2]
		X_interference[i] = rename!(DataFrame(sol_i)[:, [1, 2]], "timestamp" => :Weight, "value1" => :X)[end, 2]
	end
	X_analyte = X_analyte .* 100
	X_interference = X_interference .* 100
return X_analyte, X_interference
end

# ╔═╡ 9f33bdb1-20ea-46c7-ba1d-a75db3115e5a
X_analyte, X_interference = model(v₀, Ts)

# ╔═╡ e2887f4b-ce36-45ef-9adc-074860aa2944
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Temperature, T [K]", ylabel="Conversion, X")
	scatter!(Ts, X_analyte, label="Analyte")
	scatter!(Ts, X_interference, label="Interference")
	vlines!(400, color=(:red, 0.5), label="Optimum Temperature", linestyle="---")
	ylims!(-1., nothing)
	xlims!(270, nothing)
	axislegend(position=:rc)
	
	save("analyte-inteference.png", fig)
	
	fig
end

# ╔═╡ 7251bc44-fcf8-419a-90a1-f93f934d98bf
v₀s = [0.1, 1, 5, 10]

# ╔═╡ e70a57c7-9143-43c0-ab51-f1533a416c18
Ws = [10, 300, 1000, 10000] .* 10^-6

# ╔═╡ 0e9c63a5-1f05-4f96-954b-28dc11b2c310
vary_v₀ = [model(v₀, Ts)[1] for v₀ in v₀s]

# ╔═╡ 513acaf3-d9ab-4fb6-a3a1-04629696763d
vary_W = [model(v₀, Ts, W=W)[1] for W in Ws]

# ╔═╡ 36406455-5267-4b35-8ef4-956ee2d9c8ec
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Temperature, T [K]", ylabel="Conversion, X")
	for (i, v₀) in enumerate(v₀s) 
		scatter!(Ts, vary_v₀[i], color=colors[i], label="$v₀")
	end
	
	arrows!([360], [70], [150], [0])
	text!(410, 73, text= "Increasing v₀")

	axislegend("v₀", position=:rc)
	
	save("varying_v₀.png", fig)
	
	fig
end

# ╔═╡ 77866ad4-aaae-468b-8ba5-b7839bd62e16
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Temperature, T [K]", ylabel="Conversion, X")
	for (i, W) in enumerate(Ws) 
		scatter!(Ts, vary_W[i], color=colors[i], label="$W")
	end
	opt = model(v₀, Ts, W=0.01)[2]
	scatter!(Ts, opt, color=colors[10], label="opt_interference")
	
	
	arrows!([490], [70], [-150], [0])
	text!(400, 73, text= "Increasing W")
	vlines!(280, color=(:red, 0.5), 
			label="Optimum Temperature = 280K", linestyle="---")

	axislegend("W [mg]", position=:rb)
	
	save("varying_W.png", fig)
	
	fig
end

# ╔═╡ 6a997298-2ecd-4f8a-ae80-ea22ff4c40ff
md"""
## Residence Time Distribution
"""

# ╔═╡ b7cd7e73-2732-462d-b454-b7f356e43cee
V = 0.663

# ╔═╡ 90bd6f1a-60f1-490c-addc-4ceabe582780
begin
	τ(v₀) = V * 60/ v₀  
end

# ╔═╡ 3b054bde-88c3-429e-9a94-9651d0b42567
τs = τ.(v₀s)

# ╔═╡ 5fbb07c1-0c71-4991-a043-46f6626f54e3
τ₀ = τ(v₀)

# ╔═╡ e44e544e-a3f0-474a-943c-e73c5be866bb
ts = collect(range(0, 240, length=40))

# ╔═╡ ace37178-0e73-469e-a5d7-2129d5636b82
function F(t, τ)
	F =  zeros(length(ts))
	for (i, t) in enumerate(ts)
		if t < τ/2
			F[i] = 0
		else
			F[i] = 1 - τ^2 / (4 * t^2)
		end
	end
	return F
end

# ╔═╡ 0dcbe790-6c5e-4056-86eb-cf1a56b49d7c
Es = [E(ts, τ) for τ in τs]

# ╔═╡ 368e03b4-35c5-42b0-a122-338f284b5c80
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Time [sec]", 
				    ylabel="Cumulative residence time")

	lines!(ts, F(ts, τ₀), color=colors[1], label="F(t)")
	vlines!(τ₀, color=:red, linestyle="---", label="mean residence time")
	# for (i, τ) in enumerate(τs)
	# 	lines!(ts, F(ts, τ), color=colors[i], label="F(t)")
	# end
		
	
	axislegend(position=:rb)
	
	save("cumulative RTD.png", fig)
	
	fig
end

# ╔═╡ a961ed7e-9fca-46e8-9442-1dbdf5d01af0
begin
	local fig = Figure()
	local ax = Axis(fig[1, 1], xlabel ="Time [sec]", 
				    ylabel="Cumulative residence time")

	
	for (i, v₀) in enumerate(v₀s)
		lines!(ts, F(ts, τs[i]), color=colors[i], label="$v₀")
	end
		
	arrows!([50], [0.7], [-40], [0])
	text!(20, 0.7, text= "Increasing v₀")
	
	axislegend("v₀", position=:rc)
	
	save("vary v₀ RTD.png", fig)
	
	fig
end
<<<<<<< HEAD
=======
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
  ╠═╡ =#
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
CairoMakie = "13f3f980-e62b-5c42-98c6-ff1f3baf88f0"
ColorSchemes = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
DiffEqOperators = "9fdde737-9c7f-55bf-ade8-46b3f136cc48"
DifferentialEquations = "0c46a032-eb83-5123-abaf-570d42b7fbaa"
DomainSets = "5b8099bc-c8ec-5219-889f-1d9e522a28bf"
MethodOfLines = "94925ecb-adb7-4558-8ed8-f975c56a0bf4"
ModelingToolkit = "961ee093-0014-501f-94e3-6117800e7a78"
Optim = "429524aa-4258-5aef-a3af-852621145aeb"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
<<<<<<< HEAD
Roots = "f2b01f46-fcfa-551c-844a-d8ac1e96c665"
ScikitLearn = "3646fa90-6ef7-5e7e-9f22-8aca16db6324"
=======
<<<<<<< HEAD
Roots = "f2b01f46-fcfa-551c-844a-d8ac1e96c665"
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[compat]
CSV = "~0.10.9"
CairoMakie = "~0.10.2"
ColorSchemes = "~3.20.0"
DataFrames = "~1.5.0"
DiffEqOperators = "~4.45.0"
DifferentialEquations = "~7.7.0"
DomainSets = "~0.5.15"
MethodOfLines = "~0.8.4"
<<<<<<< HEAD
ModelingToolkit = "~8.48.1"
Optim = "~1.7.4"
PlutoUI = "~0.7.50"
Roots = "~2.0.10"
ScikitLearn = "~0.7.0"
=======
ModelingToolkit = "~8.48.0"
Optim = "~1.7.4"
PlutoUI = "~0.7.50"
Roots = "~2.0.9"
=======
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.8.5"
manifest_format = "2.0"
<<<<<<< HEAD
project_hash = "ad78c035968b81ca1b82c77376acbdbfbdf0183a"
=======
<<<<<<< HEAD
project_hash = "c4e0ba4950a066f8ce94ac72a03deea150966cab"
=======
project_hash = "a7a351fbc3dcaa971293b86ca577ab23fc241bef"
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.AbstractAlgebra]]
deps = ["GroupsCore", "InteractiveUtils", "LinearAlgebra", "MacroTools", "Markdown", "Random", "RandomExtensions", "SparseArrays", "Test"]
git-tree-sha1 = "29e65c331f97db9189ef00a4c7aed8127c2fd2d4"
uuid = "c3fe647b-3220-5bb0-a1ea-a7954cac585d"
version = "0.27.10"

[[deps.AbstractFFTs]]
deps = ["ChainRulesCore", "LinearAlgebra"]
git-tree-sha1 = "16b6dbc4cf7caee4e1e75c49485ec67b667098a0"
uuid = "621f4979-c628-5d54-868e-fcf4e3e8185c"
version = "1.3.1"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "8eaf9f1b4921132a4cff3f36a1d9ba923b14a481"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.1.4"

[[deps.AbstractTrees]]
git-tree-sha1 = "faa260e4cb5aba097a73fab382dd4b5819d8ec8c"
uuid = "1520ce14-60c1-5f80-bbc7-55ef81b5835c"
version = "0.4.4"

[[deps.Adapt]]
deps = ["LinearAlgebra", "Requires"]
git-tree-sha1 = "cc37d689f599e8df4f464b2fa3870ff7db7492ef"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "3.6.1"

[[deps.Animations]]
deps = ["Colors"]
git-tree-sha1 = "e81c509d2c8e49592413bfb0bb3b08150056c79d"
uuid = "27a7e980-b3e6-11e9-2bcd-0b925532e340"
version = "0.4.1"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.1"

[[deps.ArnoldiMethod]]
deps = ["LinearAlgebra", "Random", "StaticArrays"]
git-tree-sha1 = "62e51b39331de8911e4a7ff6f5aaf38a5f4cc0ae"
uuid = "ec485272-7323-5ecc-a04f-4719b315124d"
version = "0.2.0"

[[deps.ArrayInterface]]
deps = ["Adapt", "LinearAlgebra", "Requires", "SnoopPrecompile", "SparseArrays", "SuiteSparse"]
<<<<<<< HEAD
git-tree-sha1 = "a89acc90c551067cd84119ff018619a1a76c6277"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.2.1"
=======
<<<<<<< HEAD
git-tree-sha1 = "ec9c36854b569323551a6faf2f31fda15e3459a7"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.2.0"
=======
git-tree-sha1 = "4d9946e51e24f5e509779e3e2c06281a733914c2"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.1.0"
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.ArrayInterfaceCore]]
deps = ["LinearAlgebra", "SnoopPrecompile", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "e5f08b5689b1aad068e01751889f2f615c7db36d"
uuid = "30b0a656-2188-435a-8636-2ec0e6a096e2"
version = "0.1.29"

[[deps.ArrayLayouts]]
deps = ["FillArrays", "LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "4aff5fa660eb95c2e0deb6bcdabe4d9a96bc4667"
uuid = "4c555306-a7a7-4459-81d9-ec55ddd5c99a"
version = "0.8.18"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"

[[deps.Automa]]
deps = ["Printf", "ScanByte", "TranscodingStreams"]
git-tree-sha1 = "d50976f217489ce799e366d9561d56a98a30d7fe"
uuid = "67c07d97-cdcb-5c2c-af73-a7f9c32a568b"
version = "0.8.2"

[[deps.AxisAlgorithms]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "WoodburyMatrices"]
git-tree-sha1 = "66771c8d21c8ff5e3a93379480a2307ac36863f7"
uuid = "13072b0f-2c55-5437-9ae7-d433b7a33950"
version = "1.0.1"

[[deps.AxisArrays]]
deps = ["Dates", "IntervalSets", "IterTools", "RangeArrays"]
git-tree-sha1 = "1dd4d9f5beebac0c03446918741b1a03dc5e5788"
uuid = "39de3d68-74b9-583c-8d2d-e117c070f3a9"
version = "0.4.6"

[[deps.BandedMatrices]]
deps = ["ArrayLayouts", "FillArrays", "LinearAlgebra", "SnoopPrecompile", "SparseArrays"]
git-tree-sha1 = "ee75410471c18f40d57eb53840bc705a74566f23"
uuid = "aae01518-5342-5314-be14-df237901396f"
version = "0.17.16"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"

[[deps.Bijections]]
git-tree-sha1 = "fe4f8c5ee7f76f2198d5c2a06d3961c249cce7bd"
uuid = "e2ed5e7c-b2de-5872-ae92-c73ca462fb04"
version = "0.1.4"

[[deps.BitTwiddlingConvenienceFunctions]]
deps = ["Static"]
git-tree-sha1 = "0c5f81f47bbbcf4aea7b2959135713459170798b"
uuid = "62783981-4cbd-42fc-bca8-16325de8dc4b"
version = "0.1.5"

[[deps.BlockArrays]]
deps = ["ArrayLayouts", "FillArrays", "LinearAlgebra"]
git-tree-sha1 = "8e5457e5f1335822210ed74bacaabecf11d3bdf7"
uuid = "8e7c35d0-a365-5155-bbbb-fb81a777f24e"
version = "0.16.24"

[[deps.BlockBandedMatrices]]
deps = ["ArrayLayouts", "BandedMatrices", "BlockArrays", "FillArrays", "LinearAlgebra", "MatrixFactorizations", "SparseArrays", "Statistics"]
git-tree-sha1 = "f389a2752664c4103f9c481b4766d7eed78ad85b"
uuid = "ffab5731-97b5-5995-9138-79e8c1846df0"
version = "0.11.10"

[[deps.BoundaryValueDiffEq]]
deps = ["BandedMatrices", "DiffEqBase", "FiniteDiff", "ForwardDiff", "LinearAlgebra", "NLsolve", "Reexport", "SciMLBase", "SparseArrays"]
git-tree-sha1 = "ed8e837bfb3d1e3157022c9636ec1c722b637318"
uuid = "764a87c0-6b3e-53db-9096-fe964310641d"
version = "2.11.0"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "19a35467a82e236ff51bc17a3a44b69ef35185a2"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.8+0"

[[deps.CEnum]]
git-tree-sha1 = "eb4cb44a499229b3b8426dcfb5dd85333951ff90"
uuid = "fa961155-64e5-5f13-b03f-caf6b980ea82"
version = "0.4.2"

[[deps.CPUSummary]]
deps = ["CpuId", "IfElse", "Static"]
git-tree-sha1 = "2c144ddb46b552f72d7eafe7cc2f50746e41ea21"
uuid = "2a0fbf3d-bb9c-48f3-b0a9-814d99fd7ab9"
version = "0.2.2"

[[deps.CRC32c]]
uuid = "8bf52ea8-c179-5cab-976a-9e18b702a9bc"

[[deps.CSTParser]]
deps = ["Tokenize"]
git-tree-sha1 = "3ddd48d200eb8ddf9cb3e0189fc059fd49b97c1f"
uuid = "00ebfdb7-1f24-5e51-bd34-a7502290713f"
version = "3.3.6"

[[deps.CSV]]
deps = ["CodecZlib", "Dates", "FilePathsBase", "InlineStrings", "Mmap", "Parsers", "PooledArrays", "SentinelArrays", "SnoopPrecompile", "Tables", "Unicode", "WeakRefStrings", "WorkerUtilities"]
git-tree-sha1 = "c700cce799b51c9045473de751e9319bdd1c6e94"
uuid = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
version = "0.10.9"

[[deps.Cairo]]
deps = ["Cairo_jll", "Colors", "Glib_jll", "Graphics", "Libdl", "Pango_jll"]
git-tree-sha1 = "d0b3f8b4ad16cb0a2988c6788646a5e6a17b6b1b"
uuid = "159f3aea-2a34-519c-b102-8c37f9878175"
version = "1.0.5"

[[deps.CairoMakie]]
deps = ["Base64", "Cairo", "Colors", "FFTW", "FileIO", "FreeType", "GeometryBasics", "LinearAlgebra", "Makie", "SHA", "SnoopPrecompile"]
git-tree-sha1 = "abb7df708fe1335367518659989627100a61f3f0"
uuid = "13f3f980-e62b-5c42-98c6-ff1f3baf88f0"
version = "0.10.2"

[[deps.Cairo_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "JLLWrappers", "LZO_jll", "Libdl", "Pixman_jll", "Pkg", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "4b859a208b2397a7a623a03449e4636bdb17bcf2"
uuid = "83423d85-b0ee-5818-9007-b63ccbeb887a"
version = "1.16.1+1"

[[deps.Calculus]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f641eb0a4f00c343bbc32346e1217b86f3ce9dad"
uuid = "49dc2e85-a5d0-5ad3-a950-438e2897f1b9"
version = "0.5.1"

[[deps.ChainRulesCore]]
deps = ["Compat", "LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "c6d890a52d2c4d55d326439580c3b8d0875a77d9"
uuid = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
version = "1.15.7"

[[deps.ChangesOfVariables]]
deps = ["ChainRulesCore", "LinearAlgebra", "Test"]
git-tree-sha1 = "485193efd2176b88e6622a39a246f8c5b600e74e"
uuid = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
version = "0.1.6"

[[deps.CloseOpenIntervals]]
deps = ["Static", "StaticArrayInterface"]
git-tree-sha1 = "70232f82ffaab9dc52585e0dd043b5e0c6b714f1"
uuid = "fb6a15b2-703c-40df-9091-08a04967cfa9"
version = "0.1.12"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "9c209fb7536406834aa938fb149964b985de6c83"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.1"

[[deps.ColorBrewer]]
deps = ["Colors", "JSON", "Test"]
git-tree-sha1 = "61c5334f33d91e570e1d0c3eb5465835242582c4"
uuid = "a2cac450-b92f-5266-8821-25eda20663c8"
version = "0.4.0"

[[deps.ColorSchemes]]
deps = ["ColorTypes", "ColorVectorSpace", "Colors", "FixedPointNumbers", "Random", "SnoopPrecompile"]
git-tree-sha1 = "aa3edc8f8dea6cbfa176ee12f7c2fc82f0608ed3"
uuid = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
version = "3.20.0"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "eb7f0f8307f71fac7c606984ea5fb2817275d6e4"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.11.4"

[[deps.ColorVectorSpace]]
deps = ["ColorTypes", "FixedPointNumbers", "LinearAlgebra", "SpecialFunctions", "Statistics", "TensorCore"]
git-tree-sha1 = "600cc5508d66b78aae350f7accdb58763ac18589"
uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
version = "0.9.10"

[[deps.Colors]]
deps = ["ColorTypes", "FixedPointNumbers", "Reexport"]
git-tree-sha1 = "fc08e5930ee9a4e03f84bfb5211cb54e7769758a"
uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"
version = "0.12.10"

[[deps.Combinatorics]]
git-tree-sha1 = "08c8b6831dc00bfea825826be0bc8336fc369860"
uuid = "861a8166-3701-5b0c-9a16-15d98fcdc6aa"
version = "1.0.2"

[[deps.CommonMark]]
deps = ["Crayons", "JSON", "SnoopPrecompile", "URIs"]
git-tree-sha1 = "e2f4627b0d3f2c1876360e0b242a7c23923b469d"
uuid = "a80b9123-70ca-4bc0-993e-6e3bcb318db6"
version = "0.8.10"

[[deps.CommonSolve]]
git-tree-sha1 = "9441451ee712d1aec22edad62db1a9af3dc8d852"
uuid = "38540f10-b2f7-11e9-35d8-d573e4eb0ff2"
version = "0.2.3"

[[deps.CommonSubexpressions]]
deps = ["MacroTools", "Test"]
git-tree-sha1 = "7b8a93dba8af7e3b42fecabf646260105ac373f7"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.0"

[[deps.Compat]]
deps = ["Dates", "LinearAlgebra", "UUIDs"]
git-tree-sha1 = "7a60c856b9fa189eb34f5f8a6f6b5529b7942957"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.6.1"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.0.1+0"

[[deps.CompositeTypes]]
git-tree-sha1 = "02d2316b7ffceff992f3096ae48c7829a8aa0638"
uuid = "b152e2b5-7a66-4b01-a709-34e65c35f657"
version = "0.1.3"

[[deps.Conda]]
deps = ["Downloads", "JSON", "VersionParsing"]
git-tree-sha1 = "e32a90da027ca45d84678b826fffd3110bb3fc90"
uuid = "8f4d0f93-b110-5947-807f-2305c1781a2d"
version = "1.8.0"

[[deps.ConstructionBase]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "89a9db8d28102b094992472d333674bd1a83ce2a"
uuid = "187b0558-2788-49d3-abe0-74a17ed4e7c9"
version = "1.5.1"

[[deps.Contour]]
git-tree-sha1 = "d05d9e7b7aedff4e5b51a029dced05cfb6125781"
uuid = "d38c429a-6771-53c6-b99e-75d170b6e991"
version = "0.6.2"

[[deps.CpuId]]
deps = ["Markdown"]
git-tree-sha1 = "fcbb72b032692610bfbdb15018ac16a36cf2e406"
uuid = "adafc99b-e345-5852-983c-f28acb93d879"
version = "0.3.1"

[[deps.Crayons]]
git-tree-sha1 = "249fe38abf76d48563e2f4556bebd215aa317e15"
uuid = "a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"
version = "4.1.1"

[[deps.DataAPI]]
git-tree-sha1 = "e8119c1a33d267e16108be441a287a6981ba1630"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.14.0"

[[deps.DataFrames]]
deps = ["Compat", "DataAPI", "Future", "InlineStrings", "InvertedIndices", "IteratorInterfaceExtensions", "LinearAlgebra", "Markdown", "Missings", "PooledArrays", "PrettyTables", "Printf", "REPL", "Random", "Reexport", "SentinelArrays", "SnoopPrecompile", "SortingAlgorithms", "Statistics", "TableTraits", "Tables", "Unicode"]
git-tree-sha1 = "aa51303df86f8626a962fccb878430cdb0a97eee"
uuid = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
version = "1.5.0"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "d1fff3a548102f48987a52a2e0d114fa97d730f0"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.13"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[deps.DelayDiffEq]]
deps = ["ArrayInterface", "DataStructures", "DiffEqBase", "LinearAlgebra", "Logging", "OrdinaryDiffEq", "Printf", "RecursiveArrayTools", "Reexport", "SciMLBase", "SimpleNonlinearSolve", "SimpleUnPack"]
git-tree-sha1 = "89f3fbfe78f9d116d1ed0721d65b0b2cf9b36169"
uuid = "bcd4f6db-9728-5f36-b5f7-82caef46ccdb"
version = "5.42.0"

[[deps.DensityInterface]]
deps = ["InverseFunctions", "Test"]
git-tree-sha1 = "80c3e8639e3353e5d2912fb3a1916b8455e2494b"
uuid = "b429d917-457f-4dbc-8f4c-0cc954292b1d"
version = "0.4.0"

[[deps.DiffEqBase]]
deps = ["ArrayInterface", "ChainRulesCore", "DataStructures", "Distributions", "DocStringExtensions", "EnumX", "FastBroadcast", "ForwardDiff", "FunctionWrappers", "FunctionWrappersWrappers", "LinearAlgebra", "Logging", "Markdown", "MuladdMacro", "Parameters", "PreallocationTools", "Printf", "RecursiveArrayTools", "Reexport", "Requires", "SciMLBase", "Setfield", "SparseArrays", "Static", "StaticArraysCore", "Statistics", "Tricks", "TruncatedStacktraces", "ZygoteRules"]
git-tree-sha1 = "15a24aa2414fad34136724c4a16e556f264ddd11"
uuid = "2b5f629d-d688-5b77-993f-72d75c75574e"
version = "6.122.1"

[[deps.DiffEqCallbacks]]
deps = ["DataStructures", "DiffEqBase", "ForwardDiff", "LinearAlgebra", "Markdown", "NLsolve", "Parameters", "RecipesBase", "RecursiveArrayTools", "SciMLBase", "StaticArraysCore"]
git-tree-sha1 = "b497f63a13fe37e03ed7ac72d71b72aad17b46c4"
uuid = "459566f4-90b8-5000-8ac3-15dfb0a30def"
version = "2.26.0"

[[deps.DiffEqNoiseProcess]]
deps = ["DiffEqBase", "Distributions", "GPUArraysCore", "LinearAlgebra", "Markdown", "Optim", "PoissonRandom", "QuadGK", "Random", "Random123", "RandomNumbers", "RecipesBase", "RecursiveArrayTools", "Requires", "ResettableStacks", "SciMLBase", "StaticArrays", "Statistics"]
git-tree-sha1 = "2c4ed3eedb87579bfe9f20ecc2440de06b9f3b89"
uuid = "77a26b50-5914-5dd7-bc55-306e6241c503"
version = "5.16.0"

[[deps.DiffEqOperators]]
deps = ["BandedMatrices", "BlockBandedMatrices", "DiffEqBase", "DomainSets", "ForwardDiff", "LazyArrays", "LazyBandedMatrices", "LinearAlgebra", "LoopVectorization", "NNlib", "Requires", "RuntimeGeneratedFunctions", "SciMLBase", "SparseArrays", "SparseDiffTools", "StaticArrays", "SuiteSparse"]
git-tree-sha1 = "ef0f24d69406bf85092c843691ab2ae3b2e34b77"
uuid = "9fdde737-9c7f-55bf-ade8-46b3f136cc48"
version = "4.45.0"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "a4ad7ef19d2cdc2eff57abbbe68032b1cd0bd8f8"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.13.0"

[[deps.DifferentialEquations]]
deps = ["BoundaryValueDiffEq", "DelayDiffEq", "DiffEqBase", "DiffEqCallbacks", "DiffEqNoiseProcess", "JumpProcesses", "LinearAlgebra", "LinearSolve", "NonlinearSolve", "OrdinaryDiffEq", "Random", "RecursiveArrayTools", "Reexport", "SciMLBase", "SteadyStateDiffEq", "StochasticDiffEq", "Sundials"]
git-tree-sha1 = "ac145e3d718157c679fc4febf2fcef73ec77b067"
uuid = "0c46a032-eb83-5123-abaf-570d42b7fbaa"
version = "7.7.0"

[[deps.Distances]]
deps = ["LinearAlgebra", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "49eba9ad9f7ead780bfb7ee319f962c811c6d3b2"
uuid = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
version = "0.10.8"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"

[[deps.Distributions]]
deps = ["ChainRulesCore", "DensityInterface", "FillArrays", "LinearAlgebra", "PDMats", "Printf", "QuadGK", "Random", "SparseArrays", "SpecialFunctions", "Statistics", "StatsBase", "StatsFuns", "Test"]
<<<<<<< HEAD
git-tree-sha1 = "da9e1a9058f8d3eec3a8c9fe4faacfb89180066b"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.86"
=======
<<<<<<< HEAD
git-tree-sha1 = "fb372fc76a20edda014dfc2cdb33f23ef80feda6"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.85"
=======
git-tree-sha1 = "d71264a7b9a95dca3b8fff4477d94a837346c545"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.84"
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "2fb1e02f2b635d0845df5d7c167fec4dd739b00d"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.3"

[[deps.DomainSets]]
deps = ["CompositeTypes", "IntervalSets", "LinearAlgebra", "Random", "StaticArrays", "Statistics"]
git-tree-sha1 = "988e2db482abeb69efc76ae8b6eba2e93805ee70"
uuid = "5b8099bc-c8ec-5219-889f-1d9e522a28bf"
version = "0.5.15"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.DualNumbers]]
deps = ["Calculus", "NaNMath", "SpecialFunctions"]
git-tree-sha1 = "5837a837389fccf076445fce071c8ddaea35a566"
uuid = "fa6b7ba4-c1ee-5f82-b5fc-ecf0adba8f74"
version = "0.6.8"

[[deps.DynamicPolynomials]]
deps = ["DataStructures", "Future", "LinearAlgebra", "MultivariatePolynomials", "MutableArithmetics", "Pkg", "Reexport", "Test"]
git-tree-sha1 = "8b84876e31fa39479050e2d3395c4b3b210db8b0"
uuid = "7c1d4256-1411-5781-91ec-d7bc3513ac07"
version = "0.4.6"

[[deps.EarCut_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "e3290f2d49e661fbd94046d7e3726ffcb2d41053"
uuid = "5ae413db-bbd1-5e63-b57d-d24a61df00f5"
version = "2.2.4+0"

[[deps.EnumX]]
git-tree-sha1 = "bdb1942cd4c45e3c678fd11569d5cccd80976237"
uuid = "4e289a0a-7415-4d19-859d-a7e5c4648b56"
version = "1.0.4"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "bad72f730e9e91c08d9427d5e8db95478a3c323d"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.4.8+0"

[[deps.ExponentialUtilities]]
deps = ["Adapt", "ArrayInterface", "GPUArraysCore", "GenericSchur", "LinearAlgebra", "Printf", "SnoopPrecompile", "SparseArrays", "libblastrampoline_jll"]
git-tree-sha1 = "fb7dbef7d2631e2d02c49e2750f7447648b0ec9b"
uuid = "d4d017d3-3776-5f7e-afef-a10c40355c18"
version = "1.24.0"

[[deps.ExprTools]]
git-tree-sha1 = "c1d06d129da9f55715c6c212866f5b1bddc5fa00"
uuid = "e2ba6199-217a-4e67-a87a-7c52f15ade04"
version = "0.1.9"

[[deps.Extents]]
git-tree-sha1 = "5e1e4c53fa39afe63a7d356e30452249365fba99"
uuid = "411431e0-e8b7-467b-b5e0-f676ba4f2910"
version = "0.1.1"

[[deps.FFMPEG]]
deps = ["FFMPEG_jll"]
git-tree-sha1 = "b57e3acbe22f8484b4b5ff66a7499717fe1a9cc8"
uuid = "c87230d0-a227-11e9-1b43-d7ebe4e7570a"
version = "0.4.1"

[[deps.FFMPEG_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "JLLWrappers", "LAME_jll", "Libdl", "Ogg_jll", "OpenSSL_jll", "Opus_jll", "PCRE2_jll", "Pkg", "Zlib_jll", "libaom_jll", "libass_jll", "libfdk_aac_jll", "libvorbis_jll", "x264_jll", "x265_jll"]
git-tree-sha1 = "74faea50c1d007c85837327f6775bea60b5492dd"
uuid = "b22a6f82-2f65-5046-a5b2-351ab43fb4e5"
version = "4.4.2+2"

[[deps.FFTW]]
deps = ["AbstractFFTs", "FFTW_jll", "LinearAlgebra", "MKL_jll", "Preferences", "Reexport"]
git-tree-sha1 = "f9818144ce7c8c41edf5c4c179c684d92aa4d9fe"
uuid = "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"
version = "1.6.0"

[[deps.FFTW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c6033cc3892d0ef5bb9cd29b7f2f0331ea5184ea"
uuid = "f5851436-0d7a-5f13-b9de-f02708fd171a"
version = "3.3.10+0"

[[deps.FastBroadcast]]
deps = ["ArrayInterface", "LinearAlgebra", "Polyester", "Static", "StaticArrayInterface", "StrideArraysCore"]
git-tree-sha1 = "d1248fceea0b26493fd33e8e9e8c553270da03bd"
uuid = "7034ab61-46d4-4ed7-9d0f-46aef9175898"
version = "0.2.5"

[[deps.FastClosures]]
git-tree-sha1 = "acebe244d53ee1b461970f8910c235b259e772ef"
uuid = "9aa1b823-49e4-5ca5-8b0f-3971ec8bab6a"
version = "0.3.2"

[[deps.FastLapackInterface]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "c1293a93193f0ae94be7cf338d33e162c39d8788"
uuid = "29a986be-02c6-4525-aec4-84b980013641"
version = "1.2.9"

[[deps.FileIO]]
deps = ["Pkg", "Requires", "UUIDs"]
git-tree-sha1 = "7be5f99f7d15578798f338f5433b6c432ea8037b"
uuid = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
version = "1.16.0"

[[deps.FilePathsBase]]
deps = ["Compat", "Dates", "Mmap", "Printf", "Test", "UUIDs"]
git-tree-sha1 = "e27c4ebe80e8699540f2d6c805cc12203b614f12"
uuid = "48062228-2e41-5def-b9a4-89aafe57970f"
version = "0.9.20"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"

[[deps.FillArrays]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "Statistics"]
git-tree-sha1 = "d3ba08ab64bdfd27234d3f61956c966266757fe6"
uuid = "1a297f60-69ca-5386-bcde-b61e274b549b"
version = "0.13.7"

[[deps.FiniteDiff]]
deps = ["ArrayInterface", "LinearAlgebra", "Requires", "Setfield", "SparseArrays", "StaticArrays"]
git-tree-sha1 = "ed1b56934a2f7a65035976985da71b6a65b4f2cf"
uuid = "6a86dc24-6348-571c-b903-95158fe2bd41"
version = "2.18.0"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "335bfdceacc84c5cdf16aadc768aa5ddfc5383cc"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.4"

[[deps.Fontconfig_jll]]
deps = ["Artifacts", "Bzip2_jll", "Expat_jll", "FreeType2_jll", "JLLWrappers", "Libdl", "Libuuid_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "21efd19106a55620a188615da6d3d06cd7f6ee03"
uuid = "a3f928ae-7b40-5064-980b-68af3947d34b"
version = "2.13.93+0"

[[deps.Formatting]]
deps = ["Printf"]
git-tree-sha1 = "8339d61043228fdd3eb658d86c926cb282ae72a8"
uuid = "59287772-0a20-5a39-b81b-1366585eb4c0"
version = "0.4.2"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions", "StaticArrays"]
git-tree-sha1 = "00e252f4d706b3d55a8863432e742bf5717b498d"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "0.10.35"

[[deps.FreeType]]
deps = ["CEnum", "FreeType2_jll"]
git-tree-sha1 = "cabd77ab6a6fdff49bfd24af2ebe76e6e018a2b4"
uuid = "b38be410-82b0-50bf-ab77-7b57e271db43"
version = "4.0.0"

[[deps.FreeType2_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "87eb71354d8ec1a96d4a7636bd57a7347dde3ef9"
uuid = "d7e528f0-a631-5988-bf34-fe36492bcfd7"
version = "2.10.4+0"

[[deps.FreeTypeAbstraction]]
deps = ["ColorVectorSpace", "Colors", "FreeType", "GeometryBasics"]
git-tree-sha1 = "38a92e40157100e796690421e34a11c107205c86"
uuid = "663a7486-cb36-511b-a19d-713bb74d65c9"
version = "0.10.0"

[[deps.FriBidi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "aa31987c2ba8704e23c6c8ba8a4f769d5d7e4f91"
uuid = "559328eb-81f9-559d-9380-de523a88c83c"
version = "1.0.10+0"

[[deps.FunctionWrappers]]
git-tree-sha1 = "d62485945ce5ae9c0c48f124a84998d755bae00e"
uuid = "069b7b12-0de2-55c6-9aab-29f3d0a68a2e"
version = "1.1.3"

[[deps.FunctionWrappersWrappers]]
deps = ["FunctionWrappers"]
git-tree-sha1 = "b104d487b34566608f8b4e1c39fb0b10aa279ff8"
uuid = "77dc65aa-8811-40c2-897b-53d922fa7daf"
version = "0.1.3"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"

[[deps.GPUArraysCore]]
deps = ["Adapt"]
git-tree-sha1 = "1cd7f0af1aa58abc02ea1d872953a97359cb87fa"
uuid = "46192b85-c4d5-4398-a991-12ede77f4527"
version = "0.1.4"

[[deps.GenericSchur]]
deps = ["LinearAlgebra", "Printf"]
git-tree-sha1 = "fb69b2a645fa69ba5f474af09221b9308b160ce6"
uuid = "c145ed77-6b09-5dd9-b285-bf645a82121e"
version = "0.5.3"

[[deps.GeoInterface]]
deps = ["Extents"]
git-tree-sha1 = "e07a1b98ed72e3cdd02c6ceaab94b8a606faca40"
uuid = "cf35fbd7-0cd7-5166-be24-54bfbe79505f"
version = "1.2.1"

[[deps.GeometryBasics]]
deps = ["EarCut_jll", "GeoInterface", "IterTools", "LinearAlgebra", "StaticArrays", "StructArrays", "Tables"]
git-tree-sha1 = "fe9aea4ed3ec6afdfbeb5a4f39a2208909b162a6"
uuid = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
version = "0.4.5"

[[deps.Gettext_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "9b02998aba7bf074d14de89f9d37ca24a1a0b046"
uuid = "78b55507-aeef-58d4-861c-77aaff3498b1"
version = "0.21.0+0"

[[deps.Glib_jll]]
deps = ["Artifacts", "Gettext_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Libiconv_jll", "Libmount_jll", "PCRE2_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "d3b3624125c1474292d0d8ed0f65554ac37ddb23"
uuid = "7746bdde-850d-59dc-9ae8-88ece973131d"
version = "2.74.0+2"

[[deps.Glob]]
git-tree-sha1 = "4df9f7e06108728ebf00a0a11edee4b29a482bb2"
uuid = "c27321d9-0574-5035-807b-f59d2c89b15c"
version = "1.3.0"

[[deps.Graphics]]
deps = ["Colors", "LinearAlgebra", "NaNMath"]
git-tree-sha1 = "d61890399bc535850c4bf08e4e0d3a7ad0f21cbd"
uuid = "a2bd30eb-e257-5431-a919-1863eab51364"
version = "1.1.2"

[[deps.Graphite2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "344bf40dcab1073aca04aa0df4fb092f920e4011"
uuid = "3b182d85-2403-5c21-9c21-1e1f0cc25472"
version = "1.3.14+0"

[[deps.Graphs]]
deps = ["ArnoldiMethod", "Compat", "DataStructures", "Distributed", "Inflate", "LinearAlgebra", "Random", "SharedArrays", "SimpleTraits", "SparseArrays", "Statistics"]
git-tree-sha1 = "1cf1d7dcb4bc32d7b4a5add4232db3750c27ecb4"
uuid = "86223c79-3864-5bf0-83f7-82e725a168b6"
version = "1.8.0"

[[deps.GridLayoutBase]]
deps = ["GeometryBasics", "InteractiveUtils", "Observables"]
git-tree-sha1 = "678d136003ed5bceaab05cf64519e3f956ffa4ba"
uuid = "3955a311-db13-416c-9275-1d80ed98e5e9"
version = "0.9.1"

[[deps.Grisu]]
git-tree-sha1 = "53bb909d1151e57e2484c3d1b53e19552b887fb2"
uuid = "42e2da0e-8278-4e71-bc24-59509adca0fe"
version = "1.0.2"

[[deps.Groebner]]
deps = ["AbstractAlgebra", "Combinatorics", "Logging", "MultivariatePolynomials", "Primes", "Random"]
git-tree-sha1 = "47f0f03eddecd7ad59c42b1dd46d5f42916aff63"
uuid = "0b43b601-686d-58a3-8a1c-6623616c7cd4"
version = "0.2.11"

[[deps.GroupsCore]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "9e1a5e9f3b81ad6a5c613d181664a0efc6fe6dd7"
uuid = "d5909c97-4eac-4ecc-a3dc-fdd0858a4120"
version = "0.4.0"

[[deps.HarfBuzz_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "Graphite2_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg"]
git-tree-sha1 = "129acf094d168394e80ee1dc4bc06ec835e510a3"
uuid = "2e76f6c2-a576-52d4-95c1-20adfe4de566"
version = "2.8.1+1"

[[deps.HostCPUFeatures]]
deps = ["BitTwiddlingConvenienceFunctions", "IfElse", "Libdl", "Static"]
git-tree-sha1 = "734fd90dd2f920a2f1921d5388dcebe805b262dc"
uuid = "3e5b6fbb-0976-4d2c-9146-d79de83f2fb0"
version = "0.1.14"

[[deps.HypergeometricFunctions]]
deps = ["DualNumbers", "LinearAlgebra", "OpenLibm_jll", "SpecialFunctions", "Test"]
git-tree-sha1 = "709d864e3ed6e3545230601f94e11ebc65994641"
uuid = "34004b35-14d8-5ef3-9330-4cdb6864b03a"
version = "0.3.11"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "8d511d5b81240fc8e6802386302675bdf47737b9"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.4"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "c47c5fa4c5308f27ccaac35504858d8914e102f9"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "0.9.4"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "f7be53659ab06ddc986428d3a9dcc95f6fa6705a"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "0.2.2"

[[deps.IfElse]]
git-tree-sha1 = "debdd00ffef04665ccbb3e150747a77560e8fad1"
uuid = "615f187c-cbe4-4ef1-ba3b-2fcf58d6d173"
version = "0.1.1"

[[deps.ImageAxes]]
deps = ["AxisArrays", "ImageBase", "ImageCore", "Reexport", "SimpleTraits"]
git-tree-sha1 = "c54b581a83008dc7f292e205f4c409ab5caa0f04"
uuid = "2803e5a7-5153-5ecf-9a86-9b4c37f5f5ac"
version = "0.6.10"

[[deps.ImageBase]]
deps = ["ImageCore", "Reexport"]
git-tree-sha1 = "b51bb8cae22c66d0f6357e3bcb6363145ef20835"
uuid = "c817782e-172a-44cc-b673-b171935fbb9e"
version = "0.1.5"

[[deps.ImageCore]]
deps = ["AbstractFFTs", "ColorVectorSpace", "Colors", "FixedPointNumbers", "Graphics", "MappedArrays", "MosaicViews", "OffsetArrays", "PaddedViews", "Reexport"]
git-tree-sha1 = "acf614720ef026d38400b3817614c45882d75500"
uuid = "a09fc81d-aa75-5fe9-8630-4744c3626534"
version = "0.9.4"

[[deps.ImageIO]]
deps = ["FileIO", "IndirectArrays", "JpegTurbo", "LazyModules", "Netpbm", "OpenEXR", "PNGFiles", "QOI", "Sixel", "TiffImages", "UUIDs"]
git-tree-sha1 = "342f789fd041a55166764c351da1710db97ce0e0"
uuid = "82e4d734-157c-48bb-816b-45c225c6df19"
version = "0.6.6"

[[deps.ImageMetadata]]
deps = ["AxisArrays", "ImageAxes", "ImageBase", "ImageCore"]
git-tree-sha1 = "36cbaebed194b292590cba2593da27b34763804a"
uuid = "bc367c6b-8a6b-528e-b4bd-a4b897500b49"
version = "0.9.8"

[[deps.Imath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "87f7662e03a649cffa2e05bf19c303e168732d3e"
uuid = "905a6f67-0a94-5f89-b386-d35d92009cd1"
version = "3.1.2+0"

[[deps.IndirectArrays]]
git-tree-sha1 = "012e604e1c7458645cb8b436f8fba789a51b257f"
uuid = "9b13fd28-a010-5f03-acff-a1bbcff69959"
version = "1.0.0"

[[deps.Inflate]]
git-tree-sha1 = "5cd07aab533df5170988219191dfad0519391428"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.3"

[[deps.InlineStrings]]
deps = ["Parsers"]
git-tree-sha1 = "9cc2baf75c6d09f9da536ddf58eb2f29dedaf461"
uuid = "842dd82b-1e85-43dc-bf29-5d0ee9dffc48"
version = "1.4.0"

[[deps.IntegerMathUtils]]
git-tree-sha1 = "f366daebdfb079fd1fe4e3d560f99a0c892e15bc"
uuid = "18e54dd8-cb9d-406c-a71d-865a43cbb235"
version = "0.1.0"

[[deps.IntelOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "d979e54b71da82f3a65b62553da4fc3d18c9004c"
uuid = "1d5cc7b8-4909-519e-a0f8-d0f5ad9712d0"
version = "2018.0.3+2"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"

[[deps.Interpolations]]
deps = ["Adapt", "AxisAlgorithms", "ChainRulesCore", "LinearAlgebra", "OffsetArrays", "Random", "Ratios", "Requires", "SharedArrays", "SparseArrays", "StaticArrays", "WoodburyMatrices"]
git-tree-sha1 = "721ec2cf720536ad005cb38f50dbba7b02419a15"
uuid = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
version = "0.14.7"

[[deps.IntervalSets]]
deps = ["Dates", "Random", "Statistics"]
git-tree-sha1 = "3f91cd3f56ea48d4d2a75c2a65455c5fc74fa347"
uuid = "8197267c-284f-5f27-9208-e0e47529a953"
version = "0.7.3"

[[deps.InverseFunctions]]
deps = ["Test"]
git-tree-sha1 = "49510dfcb407e572524ba94aeae2fced1f3feb0f"
uuid = "3587e190-3f89-42d0-90ee-14403ec27112"
version = "0.1.8"

[[deps.InvertedIndices]]
git-tree-sha1 = "82aec7a3dd64f4d9584659dc0b62ef7db2ef3e19"
uuid = "41ab1584-1d38-5bbf-9106-f11c6c58b48f"
version = "1.2.0"

[[deps.IrrationalConstants]]
git-tree-sha1 = "630b497eafcc20001bba38a4651b327dcfc491d2"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.2"

[[deps.Isoband]]
deps = ["isoband_jll"]
git-tree-sha1 = "f9b6d97355599074dc867318950adaa6f9946137"
uuid = "f1662d9f-8043-43de-a69a-05efc1cc6ff4"
version = "0.1.1"

[[deps.IterTools]]
git-tree-sha1 = "fa6287a4469f5e048d763df38279ee729fbd44e5"
uuid = "c8e1da08-722c-5040-9ed9-7db0dc04731e"
version = "1.4.0"

[[deps.IterativeSolvers]]
deps = ["LinearAlgebra", "Printf", "Random", "RecipesBase", "SparseArrays"]
git-tree-sha1 = "1169632f425f79429f245113b775a0e3d121457c"
uuid = "42fd0dbc-a981-5370-80f2-aaf504508153"
version = "0.9.2"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLLWrappers]]
deps = ["Preferences"]
git-tree-sha1 = "abc9885a7ca2052a736a600f7fa66209f96506e1"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.4.1"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "3c837543ddb02250ef42f4738347454f95079d4e"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.3"

[[deps.JpegTurbo]]
deps = ["CEnum", "FileIO", "ImageCore", "JpegTurbo_jll", "TOML"]
git-tree-sha1 = "106b6aa272f294ba47e96bd3acbabdc0407b5c60"
uuid = "b835a17e-a41a-41e7-81f0-2f016b05efe0"
version = "0.1.2"

[[deps.JpegTurbo_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "6f2675ef130a300a112286de91973805fcc5ffbc"
uuid = "aacddb02-875f-59d6-b918-886e6ef4fbf8"
version = "2.1.91+0"

[[deps.JuliaFormatter]]
deps = ["CSTParser", "CommonMark", "DataStructures", "Glob", "Pkg", "SnoopPrecompile", "Tokenize"]
git-tree-sha1 = "04c4f16ef537e7b5fe0998e507cfeedc5b95b01d"
uuid = "98e50ef6-434e-11e9-1051-2b60c6c9e899"
version = "1.0.24"

[[deps.JumpProcesses]]
deps = ["ArrayInterface", "DataStructures", "DiffEqBase", "DocStringExtensions", "FunctionWrappers", "Graphs", "LinearAlgebra", "Markdown", "PoissonRandom", "Random", "RandomNumbers", "RecursiveArrayTools", "Reexport", "SciMLBase", "StaticArrays", "TreeViews", "UnPack"]
git-tree-sha1 = "7af8d30e281ce558807917b69ba16575d05f412b"
uuid = "ccbc3e58-028d-4f4c-8cd5-9ae44345cda5"
version = "9.5.1"

[[deps.KLU]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse_jll"]
git-tree-sha1 = "764164ed65c30738750965d55652db9c94c59bfe"
uuid = "ef3ab10e-7fda-4108-b977-705223b18434"
version = "0.4.0"

[[deps.KernelDensity]]
deps = ["Distributions", "DocStringExtensions", "FFTW", "Interpolations", "StatsBase"]
git-tree-sha1 = "9816b296736292a80b9a3200eb7fbb57aaa3917a"
uuid = "5ab0869b-81aa-558d-bb23-cbf5423bbe9b"
version = "0.6.5"

[[deps.Krylov]]
deps = ["LinearAlgebra", "Printf", "SparseArrays"]
git-tree-sha1 = "dd90aacbfb622f898a97c2a4411ac49101ebab8a"
uuid = "ba0b0d4f-ebba-5204-a429-3ac8c609bfb7"
version = "0.9.0"

[[deps.KrylovKit]]
deps = ["ChainRulesCore", "GPUArraysCore", "LinearAlgebra", "Printf"]
git-tree-sha1 = "1a5e1d9941c783b0119897d29f2eb665d876ecf3"
uuid = "0b1a1467-8014-51b9-945f-bf0ae24f4b77"
version = "0.6.0"

[[deps.LAME_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f6250b16881adf048549549fba48b1161acdac8c"
uuid = "c1c5ebd0-6772-5130-a774-d5fcae4a789d"
version = "3.100.1+0"

[[deps.LZO_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "e5b909bcf985c5e2605737d2ce278ed791b89be6"
uuid = "dd4b983a-f0e5-5f8d-a1b7-129d4a5fb1ac"
version = "2.10.1+0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "f2355693d6778a178ade15952b7ac47a4ff97996"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.3.0"

[[deps.LabelledArrays]]
deps = ["ArrayInterface", "ChainRulesCore", "ForwardDiff", "LinearAlgebra", "MacroTools", "PreallocationTools", "RecursiveArrayTools", "StaticArrays"]
git-tree-sha1 = "cd04158424635efd05ff38d5f55843397b7416a9"
uuid = "2ee39098-c373-598a-b85f-a56591580800"
version = "1.14.0"

[[deps.LambertW]]
git-tree-sha1 = "c5ffc834de5d61d00d2b0e18c96267cffc21f648"
uuid = "984bce1d-4616-540c-a9ee-88d1112d94c9"
version = "0.4.6"

[[deps.Latexify]]
deps = ["Formatting", "InteractiveUtils", "LaTeXStrings", "MacroTools", "Markdown", "OrderedCollections", "Printf", "Requires"]
git-tree-sha1 = "2422f47b34d4b127720a18f86fa7b1aa2e141f29"
uuid = "23fbe1c1-3f47-55db-b15f-69d7ec21a316"
version = "0.15.18"

[[deps.LayoutPointers]]
deps = ["ArrayInterface", "LinearAlgebra", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "88b8f66b604da079a627b6fb2860d3704a6729a1"
uuid = "10f19ff3-798f-405d-979b-55457f8fc047"
version = "0.1.14"

[[deps.Lazy]]
deps = ["MacroTools"]
git-tree-sha1 = "1370f8202dac30758f3c345f9909b97f53d87d3f"
uuid = "50d2b5c4-7a5e-59d5-8109-a42b560f39c0"
version = "0.15.1"

[[deps.LazyArrays]]
deps = ["ArrayLayouts", "FillArrays", "LinearAlgebra", "MacroTools", "MatrixFactorizations", "SparseArrays", "StaticArrays"]
git-tree-sha1 = "f6742270b551e03bd8ba64e1c754f5fab089ab63"
uuid = "5078a376-72f3-5289-bfd5-ec5146d43c02"
version = "0.22.16"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"

[[deps.LazyBandedMatrices]]
deps = ["ArrayLayouts", "BandedMatrices", "BlockArrays", "BlockBandedMatrices", "FillArrays", "LazyArrays", "LinearAlgebra", "MatrixFactorizations", "SparseArrays", "StaticArrays"]
git-tree-sha1 = "034d371419140f14a986ab7325d11f90f30b0c6d"
uuid = "d7e5e226-e90b-4449-9968-0f923699bf6f"
version = "0.7.17"

[[deps.LazyModules]]
git-tree-sha1 = "a560dd966b386ac9ae60bdd3a3d3a326062d3c3e"
uuid = "8cdb02fc-e678-4876-92c5-9defec4f444e"
version = "0.3.1"

[[deps.LevyArea]]
deps = ["LinearAlgebra", "Random", "SpecialFunctions"]
git-tree-sha1 = "56513a09b8e0ae6485f34401ea9e2f31357958ec"
uuid = "2d8b4e74-eb68-11e8-0fb9-d5eb67b50637"
version = "1.0.0"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.3"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "7.84.0+0"

[[deps.LibGit2]]
deps = ["Base64", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.10.2+0"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"

[[deps.Libffi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "0b4a5d71f3e5200a7dff793393e09dfc2d874290"
uuid = "e9f186c6-92d2-5b65-8a66-fee21dc1b490"
version = "3.2.2+1"

[[deps.Libgcrypt_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgpg_error_jll", "Pkg"]
git-tree-sha1 = "64613c82a59c120435c067c2b809fc61cf5166ae"
uuid = "d4300ac3-e22c-5743-9152-c294e39db1e4"
version = "1.8.7+0"

[[deps.Libgpg_error_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c333716e46366857753e273ce6a69ee0945a6db9"
uuid = "7add5ba3-2f88-524e-9cd5-f83b8a55f7b8"
version = "1.42.0+0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c7cb1f5d892775ba13767a87c7ada0b980ea0a71"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.16.1+2"

[[deps.Libmount_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9c30530bf0effd46e15e0fdcf2b8636e78cbbd73"
uuid = "4b2f31a3-9ecc-558c-b454-b3730dcb73e9"
version = "2.35.0+0"

[[deps.Libuuid_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "7f3efec06033682db852f8b3bc3c1d2b0a0ab066"
uuid = "38a345b3-de98-5d2b-a5d3-14cd9215e700"
version = "2.36.0+0"

[[deps.LineSearches]]
deps = ["LinearAlgebra", "NLSolversBase", "NaNMath", "Parameters", "Printf"]
git-tree-sha1 = "7bbea35cec17305fc70a0e5b4641477dc0789d9d"
uuid = "d3d80556-e9d4-5f37-9878-2ab0fcc64255"
version = "7.2.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[[deps.LinearSolve]]
deps = ["ArrayInterface", "DocStringExtensions", "FastLapackInterface", "GPUArraysCore", "IterativeSolvers", "KLU", "Krylov", "KrylovKit", "LinearAlgebra", "Preferences", "RecursiveFactorization", "Reexport", "SciMLBase", "SciMLOperators", "Setfield", "SnoopPrecompile", "SparseArrays", "Sparspak", "SuiteSparse", "UnPack"]
git-tree-sha1 = "fd65db5fff7238ba4c0b7a61de7e81748d73fa14"
uuid = "7ed4a6bd-45f5-4d41-b270-4a48e9bafcae"
version = "1.38.0"

[[deps.LogExpFunctions]]
deps = ["ChainRulesCore", "ChangesOfVariables", "DocStringExtensions", "InverseFunctions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "0a1b7c2863e44523180fdb3146534e265a91870b"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "0.3.23"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"

[[deps.LoopVectorization]]
deps = ["ArrayInterface", "ArrayInterfaceCore", "CPUSummary", "ChainRulesCore", "CloseOpenIntervals", "DocStringExtensions", "ForwardDiff", "HostCPUFeatures", "IfElse", "LayoutPointers", "LinearAlgebra", "OffsetArrays", "PolyesterWeave", "SIMDTypes", "SLEEFPirates", "SnoopPrecompile", "SpecialFunctions", "Static", "StaticArrayInterface", "ThreadingUtilities", "UnPack", "VectorizationBase"]
git-tree-sha1 = "2acf6874142d05d5d1ad49e8d3786b8cd800936d"
uuid = "bdcacae8-1622-11e9-2a5c-532679323890"
version = "0.12.152"

[[deps.MIMEs]]
git-tree-sha1 = "65f28ad4b594aebe22157d6fac869786a255b7eb"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "0.1.4"

[[deps.MKL_jll]]
deps = ["Artifacts", "IntelOpenMP_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "Pkg"]
git-tree-sha1 = "2ce8695e1e699b68702c03402672a69f54b8aca9"
uuid = "856f044c-d86e-5d09-b602-aeab76dc8ba7"
version = "2022.2.0+0"

[[deps.MacroTools]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "42324d08725e200c23d4dfb549e0d5d89dede2d2"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.10"

[[deps.Makie]]
deps = ["Animations", "Base64", "ColorBrewer", "ColorSchemes", "ColorTypes", "Colors", "Contour", "Distributions", "DocStringExtensions", "Downloads", "FFMPEG", "FileIO", "FixedPointNumbers", "Formatting", "FreeType", "FreeTypeAbstraction", "GeometryBasics", "GridLayoutBase", "ImageIO", "InteractiveUtils", "IntervalSets", "Isoband", "KernelDensity", "LaTeXStrings", "LinearAlgebra", "MakieCore", "Markdown", "Match", "MathTeXEngine", "MiniQhull", "Observables", "OffsetArrays", "Packing", "PlotUtils", "PolygonOps", "Printf", "Random", "RelocatableFolders", "Setfield", "Showoff", "SignedDistanceFields", "SnoopPrecompile", "SparseArrays", "StableHashTraits", "Statistics", "StatsBase", "StatsFuns", "StructArrays", "TriplotBase", "UnicodeFun"]
git-tree-sha1 = "274fa9c60a10b98ab8521886eb4fe22d257dca65"
uuid = "ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a"
version = "0.19.2"

[[deps.MakieCore]]
deps = ["Observables"]
git-tree-sha1 = "2c3fc86d52dfbada1a2e5e150e50f06c30ef149c"
uuid = "20f20a25-4f0e-4fdf-b5d1-57303727442b"
version = "0.6.2"

[[deps.ManualMemory]]
git-tree-sha1 = "bcaef4fc7a0cfe2cba636d84cda54b5e4e4ca3cd"
uuid = "d125e4d3-2237-4719-b19c-fa641b8a4667"
version = "0.1.8"

[[deps.MappedArrays]]
git-tree-sha1 = "e8b359ef06ec72e8c030463fe02efe5527ee5142"
uuid = "dbb5928d-eab1-5f90-85c2-b9b0edb7c900"
version = "0.4.1"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"

[[deps.Match]]
git-tree-sha1 = "1d9bc5c1a6e7ee24effb93f175c9342f9154d97f"
uuid = "7eb4fadd-790c-5f42-8a69-bfa0b872bfbf"
version = "1.2.0"

[[deps.MathTeXEngine]]
deps = ["AbstractTrees", "Automa", "DataStructures", "FreeTypeAbstraction", "GeometryBasics", "LaTeXStrings", "REPL", "RelocatableFolders", "Test", "UnicodeFun"]
git-tree-sha1 = "f04120d9adf4f49be242db0b905bea0be32198d1"
uuid = "0a4f8689-d25c-4efe-a92b-7142dfc1aa53"
version = "0.5.4"

[[deps.MatrixFactorizations]]
deps = ["ArrayLayouts", "LinearAlgebra", "Printf", "Random"]
git-tree-sha1 = "0ff59b4b9024ab9a736db1ad902d2b1b48441c19"
uuid = "a3b82374-2e81-5b9e-98ce-41277c0e4c87"
version = "0.9.6"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.0+0"

[[deps.MethodOfLines]]
deps = ["Combinatorics", "DiffEqBase", "DomainSets", "IfElse", "Interpolations", "Latexify", "LinearAlgebra", "ModelingToolkit", "OrdinaryDiffEq", "SciMLBase", "StaticArrays", "SymbolicUtils", "Symbolics", "TermInterface"]
git-tree-sha1 = "4cdec5b1e86affed82f680bf9cff57d146a935a0"
uuid = "94925ecb-adb7-4558-8ed8-f975c56a0bf4"
version = "0.8.4"

[[deps.MiniQhull]]
deps = ["QhullMiniWrapper_jll"]
git-tree-sha1 = "9dc837d180ee49eeb7c8b77bb1c860452634b0d1"
uuid = "978d7f02-9e05-4691-894f-ae31a51d76ca"
version = "0.4.0"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "f66bdc5de519e8f8ae43bdc598782d35a25b1272"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.1.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"

[[deps.ModelingToolkit]]
<<<<<<< HEAD
deps = ["AbstractTrees", "ArrayInterface", "Combinatorics", "Compat", "ConstructionBase", "DataStructures", "DiffEqBase", "DiffEqCallbacks", "DiffRules", "Distributed", "Distributions", "DocStringExtensions", "DomainSets", "ForwardDiff", "FunctionWrappersWrappers", "Graphs", "IfElse", "InteractiveUtils", "JuliaFormatter", "JumpProcesses", "LabelledArrays", "Latexify", "Libdl", "LinearAlgebra", "MacroTools", "NaNMath", "RecursiveArrayTools", "Reexport", "RuntimeGeneratedFunctions", "SciMLBase", "Serialization", "Setfield", "SimpleNonlinearSolve", "SparseArrays", "SpecialFunctions", "StaticArrays", "SymbolicIndexingInterface", "SymbolicUtils", "Symbolics", "UnPack", "Unitful"]
git-tree-sha1 = "c2355e8475bb127e289245d5dd0dc3224233610b"
uuid = "961ee093-0014-501f-94e3-6117800e7a78"
version = "8.48.1"
=======
<<<<<<< HEAD
deps = ["AbstractTrees", "ArrayInterface", "Combinatorics", "Compat", "ConstructionBase", "DataStructures", "DiffEqBase", "DiffEqCallbacks", "DiffRules", "Distributed", "Distributions", "DocStringExtensions", "DomainSets", "ForwardDiff", "FunctionWrappersWrappers", "Graphs", "IfElse", "InteractiveUtils", "JuliaFormatter", "JumpProcesses", "LabelledArrays", "Latexify", "Libdl", "LinearAlgebra", "MacroTools", "NaNMath", "RecursiveArrayTools", "Reexport", "RuntimeGeneratedFunctions", "SciMLBase", "Serialization", "Setfield", "SimpleNonlinearSolve", "SparseArrays", "SpecialFunctions", "StaticArrays", "SymbolicIndexingInterface", "SymbolicUtils", "Symbolics", "UnPack", "Unitful"]
git-tree-sha1 = "8ed67a1c75893cf35f4e74b27cf4485f60cc3c41"
uuid = "961ee093-0014-501f-94e3-6117800e7a78"
version = "8.48.0"
=======
deps = ["AbstractTrees", "ArrayInterfaceCore", "Combinatorics", "Compat", "ConstructionBase", "DataStructures", "DiffEqBase", "DiffEqCallbacks", "DiffRules", "Distributed", "Distributions", "DocStringExtensions", "DomainSets", "ForwardDiff", "FunctionWrappersWrappers", "Graphs", "IfElse", "InteractiveUtils", "JuliaFormatter", "JumpProcesses", "LabelledArrays", "Latexify", "Libdl", "LinearAlgebra", "MacroTools", "NaNMath", "RecursiveArrayTools", "Reexport", "RuntimeGeneratedFunctions", "SciMLBase", "Serialization", "Setfield", "SimpleNonlinearSolve", "SparseArrays", "SpecialFunctions", "StaticArrays", "SymbolicIndexingInterface", "SymbolicUtils", "Symbolics", "UnPack", "Unitful"]
git-tree-sha1 = "91ca367070ac6e98ad21563643f98e7efb26b777"
uuid = "961ee093-0014-501f-94e3-6117800e7a78"
version = "8.47.0"
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.MosaicViews]]
deps = ["MappedArrays", "OffsetArrays", "PaddedViews", "StackViews"]
git-tree-sha1 = "7b86a5d4d70a9f5cdf2dacb3cbe6d251d1a61dbe"
uuid = "e94cdb99-869f-56ef-bcf0-1ae2bcbe0389"
version = "0.3.4"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2022.2.1"

[[deps.MuladdMacro]]
git-tree-sha1 = "cac9cc5499c25554cba55cd3c30543cff5ca4fab"
uuid = "46d2c3a1-f734-5fdb-9937-b9b9aeba4221"
version = "0.2.4"

[[deps.MultivariatePolynomials]]
deps = ["ChainRulesCore", "DataStructures", "LinearAlgebra", "MutableArithmetics"]
git-tree-sha1 = "eaa98afe2033ffc0629f9d0d83961d66a021dfcc"
uuid = "102ac46a-7ee4-5c85-9060-abc95bfdeaa3"
version = "0.4.7"

[[deps.MutableArithmetics]]
deps = ["LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "3295d296288ab1a0a2528feb424b854418acff57"
uuid = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"
version = "1.2.3"

[[deps.NLSolversBase]]
deps = ["DiffResults", "Distributed", "FiniteDiff", "ForwardDiff"]
git-tree-sha1 = "a0b464d183da839699f4c79e7606d9d186ec172c"
uuid = "d41bc354-129a-5804-8e4c-c37616107c6c"
version = "7.8.3"

[[deps.NLsolve]]
deps = ["Distances", "LineSearches", "LinearAlgebra", "NLSolversBase", "Printf", "Reexport"]
git-tree-sha1 = "019f12e9a1a7880459d0173c182e6a99365d7ac1"
uuid = "2774e3e8-f4cf-5e23-947b-6d7e65073b56"
version = "4.5.1"

[[deps.NNlib]]
deps = ["Adapt", "ChainRulesCore", "LinearAlgebra", "Pkg", "Random", "Requires", "Statistics"]
git-tree-sha1 = "33ad5a19dc6730d592d8ce91c14354d758e53b0e"
uuid = "872c559c-99b0-510c-b3b7-b6c96a88d5cd"
version = "0.8.19"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "0877504529a3e5c3343c6f8b4c0381e57e4387e4"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.0.2"

[[deps.Netpbm]]
deps = ["FileIO", "ImageCore", "ImageMetadata"]
git-tree-sha1 = "5ae7ca23e13855b3aba94550f26146c01d259267"
uuid = "f09324ee-3d7c-5217-9330-fc30815ba969"
version = "1.1.0"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.NonlinearSolve]]
deps = ["ArrayInterface", "DiffEqBase", "FiniteDiff", "ForwardDiff", "LinearAlgebra", "LinearSolve", "RecursiveArrayTools", "Reexport", "SciMLBase", "SimpleNonlinearSolve", "SnoopPrecompile", "SparseArrays", "SparseDiffTools", "StaticArraysCore", "UnPack"]
git-tree-sha1 = "3f856788ba532419c07ba2e0dc37b06e5d784992"
uuid = "8913a72c-1f9b-4ce2-8d82-65094dcecaec"
version = "1.5.0"

[[deps.Observables]]
git-tree-sha1 = "6862738f9796b3edc1c09d0890afce4eca9e7e93"
uuid = "510215fc-4207-5dde-b226-833fc4488ee2"
version = "0.5.4"

[[deps.OffsetArrays]]
deps = ["Adapt"]
git-tree-sha1 = "82d7c9e310fe55aa54996e6f7f94674e2a38fcb4"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.12.9"

[[deps.Ogg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "887579a3eb005446d514ab7aeac5d1d027658b8f"
uuid = "e7412a2a-1a6e-54c0-be00-318e2571c051"
version = "1.3.5+1"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.20+0"

[[deps.OpenEXR]]
deps = ["Colors", "FileIO", "OpenEXR_jll"]
git-tree-sha1 = "327f53360fdb54df7ecd01e96ef1983536d1e633"
uuid = "52e1d378-f018-4a11-a4be-720524705ac7"
version = "0.3.2"

[[deps.OpenEXR_jll]]
deps = ["Artifacts", "Imath_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "923319661e9a22712f24596ce81c54fc0366f304"
uuid = "18a262bb-aa17-5467-a713-aee519bc75cb"
version = "3.1.1+0"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.1+0"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9ff31d101d987eb9d66bd8b176ac7c277beccd09"
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "1.1.20+0"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "13652491f6856acfd2db29360e1bbcd4565d04f1"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.5+0"

[[deps.Optim]]
deps = ["Compat", "FillArrays", "ForwardDiff", "LineSearches", "LinearAlgebra", "NLSolversBase", "NaNMath", "Parameters", "PositiveFactorizations", "Printf", "SparseArrays", "StatsBase"]
git-tree-sha1 = "1903afc76b7d01719d9c30d3c7d501b61db96721"
uuid = "429524aa-4258-5aef-a3af-852621145aeb"
version = "1.7.4"

[[deps.Opus_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51a08fb14ec28da2ec7a927c4337e4332c2a4720"
uuid = "91d4177d-7536-5919-b921-800302f37372"
version = "1.3.2+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "85f8e6578bf1f9ee0d11e7bb1b1456435479d47c"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.4.1"

[[deps.OrdinaryDiffEq]]
deps = ["Adapt", "ArrayInterface", "DataStructures", "DiffEqBase", "DocStringExtensions", "ExponentialUtilities", "FastBroadcast", "FastClosures", "FiniteDiff", "ForwardDiff", "FunctionWrappersWrappers", "IfElse", "LinearAlgebra", "LinearSolve", "Logging", "LoopVectorization", "MacroTools", "MuladdMacro", "NLsolve", "NonlinearSolve", "Polyester", "PreallocationTools", "Preferences", "RecursiveArrayTools", "Reexport", "SciMLBase", "SciMLNLSolve", "SimpleNonlinearSolve", "SimpleUnPack", "SnoopPrecompile", "SparseArrays", "SparseDiffTools", "StaticArrayInterface", "StaticArrays", "TruncatedStacktraces"]
git-tree-sha1 = "f66680b8202384c6e698ea4ec90e40c26ece1c57"
uuid = "1dea7af3-3e70-54e6-95c3-0bf5283fa5ed"
version = "6.49.1"

[[deps.PCRE2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "efcefdf7-47ab-520b-bdef-62a2eaa19f15"
version = "10.40.0+0"

[[deps.PDMats]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "67eae2738d63117a196f497d7db789821bce61d1"
uuid = "90014a1f-27ba-587c-ab20-58faa44d9150"
version = "0.11.17"

[[deps.PNGFiles]]
deps = ["Base64", "CEnum", "ImageCore", "IndirectArrays", "OffsetArrays", "libpng_jll"]
git-tree-sha1 = "f809158b27eba0c18c269cf2a2be6ed751d3e81d"
uuid = "f57f5aa1-a3ce-4bc8-8ab9-96f992907883"
version = "0.3.17"

[[deps.Packing]]
deps = ["GeometryBasics"]
git-tree-sha1 = "ec3edfe723df33528e085e632414499f26650501"
uuid = "19eb6ba3-879d-56ad-ad62-d5c202156566"
version = "0.5.0"

[[deps.PaddedViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "03a7a85b76381a3d04c7a1656039197e70eda03d"
uuid = "5432bcbf-9aad-5242-b902-cca2824c8663"
version = "0.5.11"

[[deps.Pango_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "FriBidi_jll", "Glib_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "84a314e3926ba9ec66ac097e3635e270986b0f10"
uuid = "36c8627f-9965-5494-a995-c6b170f724f3"
version = "1.50.9+0"

[[deps.Parameters]]
deps = ["OrderedCollections", "UnPack"]
git-tree-sha1 = "34c0e9ad262e5f7fc75b10a9952ca7692cfc5fbe"
uuid = "d96e819e-fc66-5662-9728-84c9c7592b0a"
version = "0.12.3"

[[deps.Parsers]]
deps = ["Dates", "SnoopPrecompile"]
git-tree-sha1 = "478ac6c952fddd4399e71d4779797c538d0ff2bf"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.5.8"

[[deps.Pixman_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "b4f5d02549a10e20780a24fce72bea96b6329e29"
uuid = "30392449-352a-5448-841d-b1acce4e97dc"
version = "0.40.1+0"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "REPL", "Random", "SHA", "Serialization", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.8.0"

[[deps.PkgVersion]]
deps = ["Pkg"]
git-tree-sha1 = "f6cf8e7944e50901594838951729a1861e668cb8"
uuid = "eebad327-c553-4316-9ea0-9fa01ccd7688"
version = "0.3.2"

[[deps.PlotUtils]]
deps = ["ColorSchemes", "Colors", "Dates", "Printf", "Random", "Reexport", "SnoopPrecompile", "Statistics"]
git-tree-sha1 = "c95373e73290cf50a8a22c3375e4625ded5c5280"
uuid = "995b91a9-d308-5afd-9ec6-746e21dbc043"
version = "1.3.4"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "JSON", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "5bb5129fdd62a2bbbe17c2756932259acf467386"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.50"

[[deps.PoissonRandom]]
deps = ["Random"]
git-tree-sha1 = "45f9da1ceee5078267eb273d065e8aa2f2515790"
uuid = "e409e4f3-bfea-5376-8464-e040bb5c01ab"
version = "0.4.3"

[[deps.Polyester]]
deps = ["ArrayInterface", "BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "ManualMemory", "PolyesterWeave", "Requires", "Static", "StaticArrayInterface", "StrideArraysCore", "ThreadingUtilities"]
git-tree-sha1 = "0fe4e7c4d8ff4c70bfa507f0dd96fa161b115777"
uuid = "f517fe37-dbe3-4b94-8317-1923a5111588"
version = "0.7.3"

[[deps.PolyesterWeave]]
deps = ["BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "Static", "ThreadingUtilities"]
git-tree-sha1 = "240d7170f5ffdb285f9427b92333c3463bf65bf6"
uuid = "1d0040c9-8b98-4ee7-8388-3f51789ca0ad"
version = "0.2.1"

[[deps.PolygonOps]]
git-tree-sha1 = "77b3d3605fc1cd0b42d95eba87dfcd2bf67d5ff6"
uuid = "647866c9-e3ac-4575-94e7-e3d426903924"
version = "0.1.2"

[[deps.PooledArrays]]
deps = ["DataAPI", "Future"]
git-tree-sha1 = "a6062fe4063cdafe78f4a0a81cfffb89721b30e7"
uuid = "2dfb63ee-cc39-5dd5-95bd-886bf059d720"
version = "1.4.2"

[[deps.PositiveFactorizations]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "17275485f373e6673f7e7f97051f703ed5b15b20"
uuid = "85a6dd25-e78a-55b7-8502-1745935b8125"
version = "0.2.4"

[[deps.PreallocationTools]]
deps = ["Adapt", "ArrayInterface", "ForwardDiff", "Requires"]
git-tree-sha1 = "f739b1b3cc7b9949af3b35089931f2b58c289163"
uuid = "d236fae5-4411-538c-8e31-a6e3d9e00b46"
version = "0.4.12"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "47e5f437cc0e7ef2ce8406ce1e7e24d44915f88d"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.3.0"

[[deps.PrettyTables]]
deps = ["Crayons", "Formatting", "LaTeXStrings", "Markdown", "Reexport", "StringManipulation", "Tables"]
git-tree-sha1 = "96f6db03ab535bdb901300f88335257b0018689d"
uuid = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
version = "2.2.2"

[[deps.Primes]]
deps = ["IntegerMathUtils"]
git-tree-sha1 = "311a2aa90a64076ea0fac2ad7492e914e6feeb81"
uuid = "27ebfcd6-29c5-5fa9-bf4b-fb8fc14df3ae"
version = "0.5.3"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[[deps.ProgressMeter]]
deps = ["Distributed", "Printf"]
git-tree-sha1 = "d7a7aef8f8f2d537104f170139553b14dfe39fe9"
uuid = "92933f4c-e287-5a05-a399-4b506db050ca"
version = "1.7.2"

[[deps.PyCall]]
deps = ["Conda", "Dates", "Libdl", "LinearAlgebra", "MacroTools", "Serialization", "VersionParsing"]
git-tree-sha1 = "62f417f6ad727987c755549e9cd88c46578da562"
uuid = "438e738f-606a-5dbb-bf0a-cddfbfd45ab0"
version = "1.95.1"

[[deps.QOI]]
deps = ["ColorTypes", "FileIO", "FixedPointNumbers"]
git-tree-sha1 = "18e8f4d1426e965c7b532ddd260599e1510d26ce"
uuid = "4b34888f-f399-49d4-9bb3-47ed5cae4e65"
version = "1.0.0"

[[deps.QhullMiniWrapper_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Qhull_jll"]
git-tree-sha1 = "607cf73c03f8a9f83b36db0b86a3a9c14179621f"
uuid = "460c41e3-6112-5d7f-b78c-b6823adb3f2d"
version = "1.0.0+1"

[[deps.Qhull_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "238dd7e2cc577281976b9681702174850f8d4cbc"
uuid = "784f63db-0788-585a-bace-daefebcd302b"
version = "8.0.1001+0"

[[deps.QuadGK]]
deps = ["DataStructures", "LinearAlgebra"]
git-tree-sha1 = "786efa36b7eff813723c4849c90456609cf06661"
uuid = "1fd47b50-473d-5c70-9696-f719f8f3bcdc"
version = "2.8.1"

[[deps.REPL]]
deps = ["InteractiveUtils", "Markdown", "Sockets", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.Random]]
deps = ["SHA", "Serialization"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"

[[deps.Random123]]
deps = ["Random", "RandomNumbers"]
git-tree-sha1 = "7a1a306b72cfa60634f03a911405f4e64d1b718b"
uuid = "74087812-796a-5b5d-8853-05524746bad3"
version = "1.6.0"

[[deps.RandomExtensions]]
deps = ["Random", "SparseArrays"]
git-tree-sha1 = "062986376ce6d394b23d5d90f01d81426113a3c9"
uuid = "fb686558-2515-59ef-acaa-46db3789a887"
version = "0.4.3"

[[deps.RandomNumbers]]
deps = ["Random", "Requires"]
git-tree-sha1 = "043da614cc7e95c703498a491e2c21f58a2b8111"
uuid = "e6cf234a-135c-5ec9-84dd-332b85af5143"
version = "1.5.3"

[[deps.RangeArrays]]
git-tree-sha1 = "b9039e93773ddcfc828f12aadf7115b4b4d225f5"
uuid = "b3c3ace0-ae52-54e7-9d0b-2c1406fd6b9d"
version = "0.3.2"

[[deps.Ratios]]
deps = ["Requires"]
git-tree-sha1 = "dc84268fe0e3335a62e315a3a7cf2afa7178a734"
uuid = "c84ed2f1-dad5-54f0-aa8e-dbefe2724439"
version = "0.4.3"

[[deps.RecipesBase]]
deps = ["SnoopPrecompile"]
git-tree-sha1 = "261dddd3b862bd2c940cf6ca4d1c8fe593e457c8"
uuid = "3cdcf5f2-1ef4-517c-9805-6587b60abb01"
version = "1.3.3"

[[deps.RecursiveArrayTools]]
deps = ["Adapt", "ArrayInterface", "ChainRulesCore", "DocStringExtensions", "FillArrays", "GPUArraysCore", "IteratorInterfaceExtensions", "LinearAlgebra", "RecipesBase", "Requires", "StaticArraysCore", "Statistics", "SymbolicIndexingInterface", "Tables", "ZygoteRules"]
git-tree-sha1 = "3dcb2a98436389c0aac964428a5fa099118944de"
uuid = "731186ca-8d62-57ce-b412-fbd966d074cd"
version = "2.38.0"

[[deps.RecursiveFactorization]]
deps = ["LinearAlgebra", "LoopVectorization", "Polyester", "SnoopPrecompile", "StrideArraysCore", "TriangularSolve"]
git-tree-sha1 = "9088515ad915c99026beb5436d0a09cd8c18163e"
uuid = "f2c3362d-daeb-58d1-803e-2bc74f2840b4"
version = "0.2.18"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.RelocatableFolders]]
deps = ["SHA", "Scratch"]
git-tree-sha1 = "90bc7a7c96410424509e4263e277e43250c05691"
uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"
version = "1.0.0"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "838a3a4188e2ded87a4f9f184b4b0d78a1e91cb7"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.3.0"

[[deps.ResettableStacks]]
deps = ["StaticArrays"]
git-tree-sha1 = "256eeeec186fa7f26f2801732774ccf277f05db9"
uuid = "ae5879a3-cd67-5da8-be7f-38c6eb64a37b"
version = "1.1.1"

[[deps.Rmath]]
deps = ["Random", "Rmath_jll"]
git-tree-sha1 = "f65dcb5fa46aee0cf9ed6274ccbd597adc49aa7b"
uuid = "79098fc4-a85e-5d69-aa6a-4863f24498fa"
version = "0.7.1"

[[deps.Rmath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "6ed52fdd3382cf21947b15e8870ac0ddbff736da"
uuid = "f50d1b31-88e8-58de-be2c-1cc44531875f"
version = "0.4.0+0"

[[deps.Roots]]
deps = ["ChainRulesCore", "CommonSolve", "Printf", "Setfield"]
<<<<<<< HEAD
git-tree-sha1 = "b45deea4566988994ebb8fb80aa438a295995a6e"
uuid = "f2b01f46-fcfa-551c-844a-d8ac1e96c665"
version = "2.0.10"
=======
git-tree-sha1 = "9c2f5d3768804ed465f0c51540c6074ae9f63900"
uuid = "f2b01f46-fcfa-551c-844a-d8ac1e96c665"
version = "2.0.9"
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.RuntimeGeneratedFunctions]]
deps = ["ExprTools", "SHA", "Serialization"]
git-tree-sha1 = "50314d2ef65fce648975a8e80ae6d8409ebbf835"
uuid = "7e49a35a-f44a-4d26-94aa-eba1b4ca6b47"
version = "0.5.5"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SIMD]]
deps = ["SnoopPrecompile"]
git-tree-sha1 = "8b20084a97b004588125caebf418d8cab9e393d1"
uuid = "fdea26ae-647d-5447-a871-4b548cad5224"
version = "3.4.4"

[[deps.SIMDTypes]]
git-tree-sha1 = "330289636fb8107c5f32088d2741e9fd7a061a5c"
uuid = "94e857df-77ce-4151-89e5-788b33177be4"
version = "0.1.0"

[[deps.SLEEFPirates]]
deps = ["IfElse", "Static", "VectorizationBase"]
git-tree-sha1 = "cda0aece8080e992f6370491b08ef3909d1c04e7"
uuid = "476501e8-09a2-5ece-8869-fb82de89a1fa"
version = "0.6.38"

[[deps.ScanByte]]
deps = ["Libdl", "SIMD"]
git-tree-sha1 = "2436b15f376005e8790e318329560dcc67188e84"
uuid = "7b38b023-a4d7-4c5e-8d43-3f3097f304eb"
version = "0.3.3"

[[deps.SciMLBase]]
deps = ["ArrayInterface", "CommonSolve", "ConstructionBase", "Distributed", "DocStringExtensions", "EnumX", "FunctionWrappersWrappers", "IteratorInterfaceExtensions", "LinearAlgebra", "Logging", "Markdown", "Preferences", "RecipesBase", "RecursiveArrayTools", "Reexport", "RuntimeGeneratedFunctions", "SciMLOperators", "SnoopPrecompile", "StaticArraysCore", "Statistics", "SymbolicIndexingInterface", "Tables", "TruncatedStacktraces"]
git-tree-sha1 = "c5876dce653513953e145316f1406e8507ec5765"
uuid = "0bca4576-84f4-4d90-8ffe-ffa030f20462"
version = "1.90.0"

[[deps.SciMLNLSolve]]
deps = ["DiffEqBase", "LineSearches", "NLsolve", "Reexport", "SciMLBase"]
git-tree-sha1 = "66c7f901dbcad51791136e2d90ee67240256ecde"
uuid = "e9a6253c-8580-4d32-9898-8661bb511710"
version = "0.1.3"

[[deps.SciMLOperators]]
deps = ["ArrayInterface", "DocStringExtensions", "Lazy", "LinearAlgebra", "Setfield", "SparseArrays", "StaticArraysCore", "Tricks"]
git-tree-sha1 = "e61e48ef909375203092a6e83508c8416df55a83"
uuid = "c0aeaf25-5076-4817-a8d5-81caf7dfa961"
version = "0.2.0"

[[deps.ScikitLearn]]
deps = ["Compat", "Conda", "DataFrames", "Distributed", "IterTools", "LinearAlgebra", "MacroTools", "Parameters", "Printf", "PyCall", "Random", "ScikitLearnBase", "SparseArrays", "StatsBase", "VersionParsing"]
git-tree-sha1 = "3df098033358431591827bb86cada0bed744105a"
uuid = "3646fa90-6ef7-5e7e-9f22-8aca16db6324"
version = "0.7.0"

[[deps.ScikitLearnBase]]
deps = ["LinearAlgebra", "Random", "Statistics"]
git-tree-sha1 = "7877e55c1523a4b336b433da39c8e8c08d2f221f"
uuid = "6e75b9c4-186b-50bd-896f-2d2496a4843e"
version = "0.5.0"

[[deps.Scratch]]
deps = ["Dates"]
git-tree-sha1 = "30449ee12237627992a99d5e30ae63e4d78cd24a"
uuid = "6c6a2e73-6563-6170-7368-637461726353"
version = "1.2.0"

[[deps.SentinelArrays]]
deps = ["Dates", "Random"]
git-tree-sha1 = "77d3c4726515dca71f6d80fbb5e251088defe305"
uuid = "91c51154-3ec4-41a3-a24f-3f23e20d615c"
version = "1.3.18"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"

[[deps.Setfield]]
deps = ["ConstructionBase", "Future", "MacroTools", "StaticArraysCore"]
git-tree-sha1 = "e2cc6d8c88613c05e1defb55170bf5ff211fbeac"
uuid = "efcf1570-3423-57d1-acb7-fd33fddbac46"
version = "1.1.1"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.Showoff]]
deps = ["Dates", "Grisu"]
git-tree-sha1 = "91eddf657aca81df9ae6ceb20b959ae5653ad1de"
uuid = "992d4aef-0814-514b-bc4d-f2e9a6c4116f"
version = "1.0.3"

[[deps.SignedDistanceFields]]
deps = ["Random", "Statistics", "Test"]
git-tree-sha1 = "d263a08ec505853a5ff1c1ebde2070419e3f28e9"
uuid = "73760f76-fbc4-59ce-8f25-708e95d2df96"
version = "0.4.0"

[[deps.SimpleNonlinearSolve]]
deps = ["ArrayInterface", "DiffEqBase", "FiniteDiff", "ForwardDiff", "LinearAlgebra", "Reexport", "Requires", "SciMLBase", "SnoopPrecompile", "StaticArraysCore"]
git-tree-sha1 = "54c78ac3cc0343a16785adabe5bbf4063c737967"
uuid = "727e6d20-b764-4bd8-a329-72de5adea6c7"
version = "0.1.14"

[[deps.SimpleTraits]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "5d7e3f4e11935503d3ecaf7186eac40602e7d231"
uuid = "699a6c99-e7fa-54fc-8d76-47d257e15c1d"
version = "0.9.4"

[[deps.SimpleUnPack]]
git-tree-sha1 = "58e6353e72cde29b90a69527e56df1b5c3d8c437"
uuid = "ce78b400-467f-4804-87d8-8f486da07d0a"
version = "1.1.0"

[[deps.Sixel]]
deps = ["Dates", "FileIO", "ImageCore", "IndirectArrays", "OffsetArrays", "REPL", "libsixel_jll"]
git-tree-sha1 = "8fb59825be681d451c246a795117f317ecbcaa28"
uuid = "45858cf5-a6b0-47a3-bbea-62219f50df47"
version = "0.1.2"

[[deps.SnoopPrecompile]]
deps = ["Preferences"]
git-tree-sha1 = "e760a70afdcd461cf01a575947738d359234665c"
uuid = "66db9d55-30c0-4569-8b51-7e840670fc0c"
version = "1.0.3"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "a4ada03f999bd01b3a25dcaa30b2d929fe537e00"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.1.0"

[[deps.SparseArrays]]
deps = ["LinearAlgebra", "Random"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[[deps.SparseDiffTools]]
deps = ["Adapt", "ArrayInterface", "Compat", "DataStructures", "FiniteDiff", "ForwardDiff", "Graphs", "LinearAlgebra", "Requires", "SparseArrays", "StaticArrays", "VertexSafeGraphs"]
git-tree-sha1 = "e19ac47477c9a8fcca06dab5e5471417d5d9d723"
uuid = "47a9eef4-7e08-11e9-0b38-333d64bd3804"
version = "1.31.0"

[[deps.Sparspak]]
deps = ["Libdl", "LinearAlgebra", "Logging", "OffsetArrays", "Printf", "SparseArrays", "Test"]
git-tree-sha1 = "342cf4b449c299d8d1ceaf00b7a49f4fbc7940e7"
uuid = "e56a9233-b9d6-4f03-8d0f-1825330902ac"
version = "0.3.9"

[[deps.SpecialFunctions]]
deps = ["ChainRulesCore", "IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "ef28127915f4229c971eb43f3fc075dd3fe91880"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.2.0"

[[deps.StableHashTraits]]
deps = ["CRC32c", "Compat", "Dates", "SHA", "Tables", "TupleTools", "UUIDs"]
git-tree-sha1 = "0b8b801b8f03a329a4e86b44c5e8a7d7f4fe10a3"
uuid = "c5dd0088-6c3f-4803-b00e-f31a60c170fa"
version = "0.3.1"

[[deps.StackViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "46e589465204cd0c08b4bd97385e4fa79a0c770c"
uuid = "cae243ae-269e-4f55-b966-ac2d0dc13c15"
version = "0.1.1"

[[deps.Static]]
deps = ["IfElse"]
git-tree-sha1 = "d0435ba43ab5ad1cbb5f0d286ca4ba67029ed3ee"
uuid = "aedffcd0-7271-4cad-89d0-dc628f76c6d3"
version = "0.8.4"

[[deps.StaticArrayInterface]]
deps = ["ArrayInterface", "Compat", "IfElse", "LinearAlgebra", "Requires", "SnoopPrecompile", "SparseArrays", "Static", "SuiteSparse"]
git-tree-sha1 = "fd5f417fd7e103c121b0a0b4a6902f03991111f4"
uuid = "0d7ed370-da01-4f52-bd93-41d350b8b718"
version = "1.3.0"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "Random", "StaticArraysCore", "Statistics"]
git-tree-sha1 = "2d7d9e1ddadc8407ffd460e24218e37ef52dd9a3"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.5.16"

[[deps.StaticArraysCore]]
git-tree-sha1 = "6b7ba252635a5eff6a0b0664a41ee140a1c9e72a"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.0"

[[deps.Statistics]]
deps = ["LinearAlgebra", "SparseArrays"]
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

[[deps.StatsAPI]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f9af7f195fb13589dd2e2d57fdb401717d2eb1f6"
uuid = "82ae8749-77ed-4fe6-ae5f-f523153014b0"
version = "1.5.0"

[[deps.StatsBase]]
deps = ["DataAPI", "DataStructures", "LinearAlgebra", "LogExpFunctions", "Missings", "Printf", "Random", "SortingAlgorithms", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "d1bf48bfcc554a3761a133fe3a9bb01488e06916"
uuid = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
version = "0.33.21"

[[deps.StatsFuns]]
deps = ["ChainRulesCore", "HypergeometricFunctions", "InverseFunctions", "IrrationalConstants", "LogExpFunctions", "Reexport", "Rmath", "SpecialFunctions"]
<<<<<<< HEAD
git-tree-sha1 = "f625d686d5a88bcd2b15cd81f18f98186fdc0c9a"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.3.0"
=======
<<<<<<< HEAD
git-tree-sha1 = "f625d686d5a88bcd2b15cd81f18f98186fdc0c9a"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.3.0"
=======
git-tree-sha1 = "5aa6250a781e567388f3285fb4b0f214a501b4d5"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.2.1"
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59

[[deps.SteadyStateDiffEq]]
deps = ["DiffEqBase", "DiffEqCallbacks", "LinearAlgebra", "NLsolve", "Reexport", "SciMLBase"]
git-tree-sha1 = "04a7d0bb1c824857ba0bb0c17bc5950dccbfdd5d"
uuid = "9672c7b4-1e72-59bd-8a11-6ac3964bc41f"
version = "1.14.0"

[[deps.StochasticDiffEq]]
deps = ["Adapt", "ArrayInterface", "DataStructures", "DiffEqBase", "DiffEqNoiseProcess", "DocStringExtensions", "FillArrays", "FiniteDiff", "ForwardDiff", "JumpProcesses", "LevyArea", "LinearAlgebra", "Logging", "MuladdMacro", "NLsolve", "OrdinaryDiffEq", "Random", "RandomNumbers", "RecursiveArrayTools", "Reexport", "SciMLBase", "SparseArrays", "SparseDiffTools", "StaticArrays", "UnPack"]
git-tree-sha1 = "c6b4b802d4d830e0e958f5f2098d8dea0a935f4b"
uuid = "789caeaf-c7a9-5a7d-9973-96adeb23e2a0"
version = "6.58.0"

[[deps.StrideArraysCore]]
deps = ["ArrayInterface", "CloseOpenIntervals", "IfElse", "LayoutPointers", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface", "ThreadingUtilities"]
git-tree-sha1 = "2842f1dbd12d59f2728ba79f4002cd6b61808f8b"
uuid = "7792a7ef-975c-4747-a70f-980b88e8d1da"
version = "0.4.8"

[[deps.StringManipulation]]
git-tree-sha1 = "46da2434b41f41ac3594ee9816ce5541c6096123"
uuid = "892a3eda-7b42-436c-8928-eab12a02cf0e"
version = "0.3.0"

[[deps.StructArrays]]
deps = ["Adapt", "DataAPI", "GPUArraysCore", "StaticArraysCore", "Tables"]
git-tree-sha1 = "b03a3b745aa49b566f128977a7dd1be8711c5e71"
uuid = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
version = "0.6.14"

[[deps.SuiteSparse]]
deps = ["Libdl", "LinearAlgebra", "Serialization", "SparseArrays"]
uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "Pkg", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "5.10.1+0"

[[deps.Sundials]]
deps = ["CEnum", "DataStructures", "DiffEqBase", "Libdl", "LinearAlgebra", "Logging", "Reexport", "SciMLBase", "SnoopPrecompile", "SparseArrays", "Sundials_jll"]
git-tree-sha1 = "c033830e3c6fb4260243fc907b1e7e93421e7ae8"
uuid = "c3572dad-4567-51f8-b174-8c6c989267f4"
version = "4.15.1"

[[deps.Sundials_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "OpenBLAS_jll", "Pkg", "SuiteSparse_jll"]
git-tree-sha1 = "04777432d74ec5bc91ca047c9e0e0fd7f81acdb6"
uuid = "fb77eaff-e24c-56d4-86b1-d163f2edb164"
version = "5.2.1+0"

[[deps.SymbolicIndexingInterface]]
deps = ["DocStringExtensions"]
git-tree-sha1 = "f8ab052bfcbdb9b48fad2c80c873aa0d0344dfe5"
uuid = "2efcf032-c050-4f8e-a9bb-153293bab1f5"
version = "0.2.2"

[[deps.SymbolicUtils]]
deps = ["AbstractTrees", "Bijections", "ChainRulesCore", "Combinatorics", "ConstructionBase", "DataStructures", "DocStringExtensions", "DynamicPolynomials", "IfElse", "LabelledArrays", "LinearAlgebra", "MultivariatePolynomials", "NaNMath", "Setfield", "SparseArrays", "SpecialFunctions", "StaticArrays", "TimerOutputs", "Unityper"]
git-tree-sha1 = "ca0dbe8434ace322cea02fc8cce0dea8d5308e87"
uuid = "d1185830-fcd6-423d-90d6-eec64667417b"
version = "1.0.3"

[[deps.Symbolics]]
deps = ["ArrayInterface", "ConstructionBase", "DataStructures", "DiffRules", "Distributions", "DocStringExtensions", "DomainSets", "Groebner", "IfElse", "LaTeXStrings", "LambertW", "Latexify", "Libdl", "LinearAlgebra", "MacroTools", "Markdown", "NaNMath", "RecipesBase", "Reexport", "Requires", "RuntimeGeneratedFunctions", "SciMLBase", "Setfield", "SparseArrays", "SpecialFunctions", "StaticArrays", "SymbolicUtils", "TreeViews"]
git-tree-sha1 = "fce1fd0b13f860128c8b8aab0bab475eeeeb7994"
uuid = "0c5d862f-8b57-4792-8d23-62f2024744c7"
version = "5.1.0"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.0"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "LinearAlgebra", "OrderedCollections", "TableTraits", "Test"]
git-tree-sha1 = "c79322d36826aa2f4fd8ecfa96ddb47b174ac78d"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.10.0"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.1"

[[deps.TensorCore]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1feb45f88d133a655e001435632f019a9a1bcdb6"
uuid = "62fd8b95-f654-4bbd-a8a5-9c27f68ccd50"
version = "0.1.1"

[[deps.TermInterface]]
git-tree-sha1 = "3939db0ce564b5fda6e9f9edcb4dabe0a1a0cc5f"
uuid = "8ea1fca8-c5ef-4a55-8b96-4e9afe9c9a3c"
version = "0.3.3"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.ThreadingUtilities]]
deps = ["ManualMemory"]
git-tree-sha1 = "c97f60dd4f2331e1a495527f80d242501d2f9865"
uuid = "8290d209-cae3-49c0-8002-c8c24d57dab5"
version = "0.5.1"

[[deps.TiffImages]]
deps = ["ColorTypes", "DataStructures", "DocStringExtensions", "FileIO", "FixedPointNumbers", "IndirectArrays", "Inflate", "Mmap", "OffsetArrays", "PkgVersion", "ProgressMeter", "UUIDs"]
git-tree-sha1 = "7e6b0e3e571be0b4dd4d2a9a3a83b65c04351ccc"
uuid = "731e570b-9d59-4bfa-96dc-6df516fadf69"
version = "0.6.3"

[[deps.TimerOutputs]]
deps = ["ExprTools", "Printf"]
git-tree-sha1 = "f2fd3f288dfc6f507b0c3a2eb3bac009251e548b"
uuid = "a759f4b9-e2f1-59dc-863e-4aeb61b1ea8f"
version = "0.5.22"

[[deps.Tokenize]]
git-tree-sha1 = "90538bf898832b6ebd900fa40f223e695970e3a5"
uuid = "0796e94c-ce3b-5d07-9a54-7f471281c624"
version = "0.5.25"

[[deps.TranscodingStreams]]
deps = ["Random", "Test"]
git-tree-sha1 = "94f38103c984f89cf77c402f2a68dbd870f8165f"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.9.11"

[[deps.TreeViews]]
deps = ["Test"]
git-tree-sha1 = "8d0d7a3fe2f30d6a7f833a5f19f7c7a5b396eae6"
uuid = "a2a6695c-b41b-5b7d-aed9-dbfdeacea5d7"
version = "0.3.0"

[[deps.TriangularSolve]]
deps = ["CloseOpenIntervals", "IfElse", "LayoutPointers", "LinearAlgebra", "LoopVectorization", "Polyester", "Static", "VectorizationBase"]
git-tree-sha1 = "31eedbc0b6d07c08a700e26d31298ac27ef330eb"
uuid = "d5829a12-d9aa-46ab-831f-fb7c9ab06edf"
version = "0.1.19"

[[deps.Tricks]]
git-tree-sha1 = "6bac775f2d42a611cdfcd1fb217ee719630c4175"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.6"

[[deps.TriplotBase]]
git-tree-sha1 = "4d4ed7f294cda19382ff7de4c137d24d16adc89b"
uuid = "981d1d27-644d-49a2-9326-4793e63143c3"
version = "0.1.0"

[[deps.TruncatedStacktraces]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "f7057ba94e63b269125c0db75dcdef913d956351"
uuid = "781d530d-4396-4725-bb49-402e4bee1e77"
version = "1.1.0"

[[deps.TupleTools]]
git-tree-sha1 = "3c712976c47707ff893cf6ba4354aa14db1d8938"
uuid = "9d95972d-f1c8-5527-a6e0-b4b365fa01f6"
version = "1.3.0"

[[deps.URIs]]
git-tree-sha1 = "074f993b0ca030848b897beff716d93aca60f06a"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.4.2"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

[[deps.UnPack]]
git-tree-sha1 = "387c1f73762231e86e0c9c5443ce3b4a0a9a0c2b"
uuid = "3a884ed6-31ef-47d7-9d2a-63182c4928ed"
version = "1.0.2"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"

[[deps.UnicodeFun]]
deps = ["REPL"]
git-tree-sha1 = "53915e50200959667e78a92a418594b428dffddf"
uuid = "1cfade01-22cf-5700-b092-accc4b62d6e1"
version = "0.4.1"

[[deps.Unitful]]
deps = ["ConstructionBase", "Dates", "LinearAlgebra", "Random"]
git-tree-sha1 = "bb37ed24f338bc59b83e3fc9f32dd388e5396c53"
uuid = "1986cc42-f94f-5a68-af5c-568840ba703d"
version = "1.12.4"

[[deps.Unityper]]
deps = ["ConstructionBase"]
git-tree-sha1 = "d5f4ec8c22db63bd3ccb239f640e895cfde145aa"
uuid = "a7c27f48-0311-42f6-a7f8-2c11e75eb415"
version = "0.1.2"

[[deps.VectorizationBase]]
deps = ["ArrayInterface", "CPUSummary", "HostCPUFeatures", "IfElse", "LayoutPointers", "Libdl", "LinearAlgebra", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "a2d69abfc8b9b71a5db110f9757d0cd4a27877c0"
uuid = "3d5dd08c-fd9d-11e8-17fa-ed2836048c2f"
version = "0.21.61"

[[deps.VersionParsing]]
git-tree-sha1 = "58d6e80b4ee071f5efd07fda82cb9fbe17200868"
uuid = "81def892-9a0e-5fdd-b105-ffc91e053289"
version = "1.3.0"

[[deps.VertexSafeGraphs]]
deps = ["Graphs"]
git-tree-sha1 = "8351f8d73d7e880bfc042a8b6922684ebeafb35c"
uuid = "19fa3120-7c27-5ec5-8db8-b0b0aa330d6f"
version = "0.2.0"

[[deps.WeakRefStrings]]
deps = ["DataAPI", "InlineStrings", "Parsers"]
git-tree-sha1 = "b1be2855ed9ed8eac54e5caff2afcdb442d52c23"
uuid = "ea10d353-3f73-51f8-a26c-33c1cb351aa5"
version = "1.4.2"

[[deps.WoodburyMatrices]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "de67fa59e33ad156a590055375a30b23c40299d3"
uuid = "efce3f68-66dc-5838-9240-27a6d6f5f9b6"
version = "0.5.5"

[[deps.WorkerUtilities]]
git-tree-sha1 = "cd1659ba0d57b71a464a29e64dbc67cfe83d54e7"
uuid = "76eceee3-57b5-4d4a-8e66-0e911cebbf60"
version = "1.6.1"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "93c41695bc1c08c46c5899f4fe06d6ead504bb73"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.10.3+0"

[[deps.XSLT_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgcrypt_jll", "Libgpg_error_jll", "Libiconv_jll", "Pkg", "XML2_jll", "Zlib_jll"]
git-tree-sha1 = "91844873c4085240b95e795f692c4cec4d805f8a"
uuid = "aed1982a-8fda-507f-9586-7b0439959a61"
version = "1.1.34+0"

[[deps.Xorg_libX11_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libxcb_jll", "Xorg_xtrans_jll"]
git-tree-sha1 = "5be649d550f3f4b95308bf0183b82e2582876527"
uuid = "4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"
version = "1.6.9+4"

[[deps.Xorg_libXau_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4e490d5c960c314f33885790ed410ff3a94ce67e"
uuid = "0c0b7dd1-d40b-584c-a123-a41640f87eec"
version = "1.0.9+4"

[[deps.Xorg_libXdmcp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fe47bd2247248125c428978740e18a681372dd4"
uuid = "a3789734-cfe1-5b06-b2d0-1dd0d9d62d05"
version = "1.1.3+4"

[[deps.Xorg_libXext_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "b7c0aa8c376b31e4852b360222848637f481f8c3"
uuid = "1082639a-0dae-5f34-9b06-72781eeb8cb3"
version = "1.3.4+4"

[[deps.Xorg_libXrender_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "19560f30fd49f4d4efbe7002a1037f8c43d43b96"
uuid = "ea2f1a96-1ddc-540d-b46f-429655e07cfa"
version = "0.9.10+4"

[[deps.Xorg_libpthread_stubs_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "6783737e45d3c59a4a4c4091f5f88cdcf0908cbb"
uuid = "14d82f49-176c-5ed1-bb49-ad3f5cbd8c74"
version = "0.1.0+3"

[[deps.Xorg_libxcb_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "XSLT_jll", "Xorg_libXau_jll", "Xorg_libXdmcp_jll", "Xorg_libpthread_stubs_jll"]
git-tree-sha1 = "daf17f441228e7a3833846cd048892861cff16d6"
uuid = "c7cfdc94-dc32-55de-ac96-5a1b8d977c5b"
version = "1.13.0+3"

[[deps.Xorg_xtrans_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "79c31e7844f6ecf779705fbc12146eb190b7d845"
uuid = "c5fb5394-a638-5e4d-96e5-b29de1b5cf10"
version = "1.4.0+3"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.2.12+3"

[[deps.ZygoteRules]]
deps = ["MacroTools"]
git-tree-sha1 = "8c1a8e4dfacb1fd631745552c8db35d0deb09ea0"
uuid = "700de1a5-db45-46bc-99cf-38207098b444"
version = "0.2.2"

[[deps.isoband_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51b5eeb3f98367157a7a12a1fb0aa5328946c03c"
uuid = "9a68df92-36a6-505f-a73e-abb412b6bfb4"
version = "0.2.3+0"

[[deps.libaom_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3a2ea60308f0996d26f1e5354e10c24e9ef905d4"
uuid = "a4ae2306-e953-59d6-aa16-d00cac43593b"
version = "3.4.0+0"

[[deps.libass_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "5982a94fcba20f02f42ace44b9894ee2b140fe47"
uuid = "0ac62f75-1d6f-5e53-bd7c-93b484bb37c0"
version = "0.15.1+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl", "OpenBLAS_jll"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.1.1+0"

[[deps.libfdk_aac_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "daacc84a041563f965be61859a36e17c4e4fcd55"
uuid = "f638f0a6-7fb0-5443-88ba-1cc74229b280"
version = "2.0.2+0"

[[deps.libpng_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "94d180a6d2b5e55e447e2d27a29ed04fe79eb30c"
uuid = "b53b4c65-9356-5827-b1ea-8c7a1a84506f"
version = "1.6.38+0"

[[deps.libsixel_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Pkg", "libpng_jll"]
git-tree-sha1 = "d4f63314c8aa1e48cd22aa0c17ed76cd1ae48c3c"
uuid = "075b6546-f08a-558a-be8f-8157d0f608a5"
version = "1.10.3+0"

[[deps.libvorbis_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ogg_jll", "Pkg"]
git-tree-sha1 = "b910cb81ef3fe6e78bf6acee440bda86fd6ae00c"
uuid = "f27f6e37-5d2b-51aa-960f-b287f2bc3b7a"
version = "1.3.7+1"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.48.0+0"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.4.0+0"

[[deps.x264_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fea590b89e6ec504593146bf8b988b2c00922b2"
uuid = "1270edf5-f2f9-52d2-97e9-ab00b5d0237a"
version = "2021.5.5+0"

[[deps.x265_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ee567a171cce03570d77ad3a43e90218e38937a9"
uuid = "dfaa095f-4041-5dcd-9319-2fabd8486b76"
version = "3.5.0+0"
"""

# ╔═╡ Cell order:
# ╠═5ecc9a90-acc7-11ed-1233-43da78353190
# ╠═b456ab98-c614-45ca-92a8-4a63634c4991
# ╠═73956355-f662-4d50-bb07-f4ffbd91f99f
# ╠═352b723f-c67e-4a2a-b53d-b131fc5debbc
# ╠═e2444136-3e5a-4be6-b81b-0c8b330b50e5
# ╟─b0159335-af41-4523-89c1-07dbff30c298
# ╟─ba885028-fc4c-4605-adca-97b0bc063901
# ╟─0f13982d-26a5-43a1-bba1-6e3e3659277a
# ╠═95a86945-9001-4dc4-85b0-336259c30929
# ╠═093a6227-734f-4ac6-b0c0-f676f2d1eb67
# ╟─0cb2b595-2ee6-44e8-81ce-2497352625b2
# ╠═034129ed-c1a0-4fab-ba42-381fe227c0b0
# ╠═bce5bf5b-d943-4a05-a6c4-a00f2f296f57
# ╠═b0db17f8-0ebe-4412-ab1c-3c5a62e4c786
# ╟─3755f3d2-a1bc-4519-8562-1415dcd57b21
# ╠═ab43c1ff-dff8-4b15-9b0d-f1938c78ed59
# ╠═33c569c3-7c98-49a9-b9dd-77ec56957111
# ╟─8d5588b4-8eab-44ed-9921-d96b6f1bf21b
# ╠═eeedcd3e-72ea-48b8-88a6-3e9a6edb3a6d
# ╠═dce8c693-36ff-4d37-9922-ebba0338602f
# ╠═b77cc6d2-7ff9-4fcc-9196-55a1912b2e67
# ╠═43d9317c-4206-41ef-ab7a-fadb73f5cc57
# ╠═439d93ee-4a14-40e4-83d1-2508804cb79f
# ╠═dbc3182d-5b9e-4f41-b4e5-586b98f89fae
# ╠═239fd31b-84d1-4dca-98f0-4889a930e54d
# ╠═a5de549f-c300-426d-93c4-1b8e3df358f2
<<<<<<< HEAD
# ╠═5a461d73-e6f9-4584-a2ac-962e68a8eb17
# ╠═7c56fa73-f7b8-4f21-8080-875d82c9e170
# ╠═f922a709-b553-4888-99e4-1795056cfa46
=======
<<<<<<< HEAD
# ╠═aaee7564-5417-4ece-a115-be412614ceba
# ╠═2a5d417b-6d8c-43ca-b143-3dc3c98903a9
# ╠═f922a709-b553-4888-99e4-1795056cfa46
# ╠═22a9000e-79d2-42e0-9d5f-0fb703dc8fc5
# ╠═5a461d73-e6f9-4584-a2ac-962e68a8eb17
# ╠═7c56fa73-f7b8-4f21-8080-875d82c9e170
# ╠═ca188d5a-eb67-44c1-b6c0-ea4124b878bb
# ╠═2b3f63ed-24cc-42a7-a7a4-9136b91093fb
# ╠═80ef01e9-65d6-4668-a5a4-7d562b65234b
# ╠═d49fa061-642f-434d-a3c7-de5d68d92eb9
# ╠═b78e66a4-f891-4b3b-ad3a-3355dc58f5c7
# ╠═8f9a55bd-0354-4e73-88e5-408792709a2b
# ╠═ed404504-75ff-45f3-8aed-ebcc2be62ec1
# ╠═34936add-e8ad-4300-96e7-52016ea95a77
# ╠═7e8ae5f7-0d4f-46d2-a313-cfcdfb7e07a9
# ╠═9756ded3-2f58-4463-a706-42cc5cb382ff
# ╠═e2887f4b-ce36-45ef-9adc-074860aa2944
=======
# ╠═00c7ce53-3317-4265-bde6-b90364e96763
# ╠═7970cc8b-4feb-489c-a46b-c4e0ef175054
# ╠═bd44687a-ae4c-4646-9ea7-f1dbacd5e37b
# ╠═71280fbc-b054-4d10-b4a3-3579393a090c
# ╠═1081a6d9-c980-47bf-a117-73a574c4b287
# ╠═976d8d06-ccb5-4984-adc8-e0945aee58d1
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59
# ╠═8b1e0bfd-19d0-497a-96aa-3f22b0565371
# ╟─00c7ce53-3317-4265-bde6-b90364e96763
# ╠═ca188d5a-eb67-44c1-b6c0-ea4124b878bb
# ╠═29a76bde-f13e-429a-83a0-6a2aa2e6d630
# ╠═dfb10f69-0b77-46f3-9f1e-ba94cdd6c131
# ╠═35a219e8-800e-44a3-8f67-e77b148ab47b
# ╠═7b5b6f35-94d8-4647-a888-3b5bbe17f656
# ╠═ea27a021-0ccc-4b5c-a049-fe285985d661
# ╠═ae232c11-0447-4fa0-a889-87968b72da93
# ╠═2a5d417b-6d8c-43ca-b143-3dc3c98903a9
# ╠═dfb407dc-f86a-4279-a85d-ff82c70beaeb
<<<<<<< HEAD
# ╠═b78e66a4-f891-4b3b-ad3a-3355dc58f5c7
# ╠═82e72ff5-d6e6-4ac5-beac-4eb3b0efe5ad
# ╠═a3f63c04-a2ff-4b8a-8261-0d9ac195c1c9
# ╠═9756ded3-2f58-4463-a706-42cc5cb382ff
# ╠═9f33bdb1-20ea-46c7-ba1d-a75db3115e5a
# ╠═e2887f4b-ce36-45ef-9adc-074860aa2944
# ╠═7251bc44-fcf8-419a-90a1-f93f934d98bf
# ╠═e70a57c7-9143-43c0-ab51-f1533a416c18
# ╠═0e9c63a5-1f05-4f96-954b-28dc11b2c310
# ╠═513acaf3-d9ab-4fb6-a3a1-04629696763d
# ╠═36406455-5267-4b35-8ef4-956ee2d9c8ec
# ╠═77866ad4-aaae-468b-8ba5-b7839bd62e16
# ╟─6a997298-2ecd-4f8a-ae80-ea22ff4c40ff
# ╠═b7cd7e73-2732-462d-b454-b7f356e43cee
# ╠═90bd6f1a-60f1-490c-addc-4ceabe582780
# ╠═3b054bde-88c3-429e-9a94-9651d0b42567
# ╠═5fbb07c1-0c71-4991-a043-46f6626f54e3
# ╠═e44e544e-a3f0-474a-943c-e73c5be866bb
# ╠═ace37178-0e73-469e-a5d7-2129d5636b82
# ╠═0dcbe790-6c5e-4056-86eb-cf1a56b49d7c
# ╠═368e03b4-35c5-42b0-a122-338f284b5c80
# ╠═a961ed7e-9fca-46e8-9442-1dbdf5d01af0
=======
# ╠═202ab015-4b58-45c6-a3f4-e6b028cc9fe1
# ╠═835605a7-613c-4927-bbfc-67e93dffd9d8
# ╠═0eb30e88-6010-4b08-9506-d0ef147b7a48
# ╠═ab167bb1-4b7b-4b11-96ef-f8ca4aa665be
# ╠═1a2a9454-957a-4223-a825-0af535432297
>>>>>>> bdd9a058aeeecbcb0d85c881ae58ac4b2b39c883
>>>>>>> c4e5ad69e91a08b580338888b292b97b6b460e59
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
