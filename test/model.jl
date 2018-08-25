@testset "optimizehook" begin
    m = Model()
    @test m.optimizehook === nothing
    called = false
    function hook(m)
        called = true
    end
    JuMP.setoptimizehook(m, hook)
    @test !called
    optimize(m)
    @test called
end
@testset "UniversalFallback" begin
    m = Model()
    MOI.set!(m, MOIT.UnknownModelAttribute(), 1)
    @test MOI.get(m, MOIT.UnknownModelAttribute()) == 1
end
# Simple LP model not supporting Interval
@MOIU.model LPModel () (EqualTo, GreaterThan, LessThan) () () (SingleVariable,) (ScalarAffineFunction,) () ()
@testset "Bridges" begin
    @testset "Automatic bridging" begin
        # optimizer not supporting Interval
        model = Model(with_optimizer(MOIU.MockOptimizer, LPModel{Float64}()))
        @variable model x
        cref = @constraint model 0 <= x + 1 <= 1
        @test cref isa JuMP.ConstraintRef{JuMP.Model,MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},MOI.Interval{Float64}}}
        JuMP.optimize(model)
    end
    @testset "Automatic bridging disabled with `bridge_constraints` keyword" begin
        model = Model(with_optimizer(MOIU.MockOptimizer, LPModel{Float64}()), bridge_constraints=false)
        @test model.moibackend isa MOIU.CachingOptimizer
        @test model.moibackend === JuMP.caching_optimizer(model)
        @variable model x
        @test_throws ErrorException @constraint model 0 <= x + 1 <= 1
    end
    @testset "No bridge automatically added in Direct mode" begin
        optimizer = MOIU.MockOptimizer(LPModel{Float64}())
        model = JuMP.direct_model(optimizer)
        @variable model x
        @test_throws ErrorException @constraint model 0 <= x + 1 <= 1
    end
end

struct Optimizer
    a::Int
    b::Int
end
function f(a::Int; b::Int = 1)
    return Optimizer(a, b)
end

@testset "Factories" begin
    factory = with_optimizer(Optimizer, 1, 2)
    @test factory.constructor == Optimizer
    @test factory.args == (1, 2)
    optimizer = factory()
    @test optimizer isa Optimizer
    @test optimizer.a == 1
    @test optimizer.b == 2
    @test_throws ErrorException factory = with_optimizer(f, 1, 2)
    factory = with_optimizer(f, 1, b = 2)
    @test factory.constructor == f
    @test factory.args == (1,)
    optimizer = factory()
    @test optimizer isa Optimizer
    @test optimizer.a == 1
    @test optimizer.b == 2
end

struct DummyExtensionData
    model::JuMP.Model
end
function JuMP.copy_extension_data(data::DummyExtensionData,
                                  new_model::JuMP.AbstractModel,
                                  model::JuMP.AbstractModel)
    @test data.model === model
    return DummyExtensionData(new_model)
end
function dummy_optimizer_hook(::JuMP.AbstractModel) end

@testset "Model copy" begin
    for caching_mode in (MOIU.Automatic, MOIU.Manual)
        @testset "In $caching_mode mode" begin
            for bridge_constraints in (false, true)
                model = Model(caching_mode = caching_mode,
                              bridge_constraints = bridge_constraints)
                model.optimizehook = dummy_optimizer_hook
                data = DummyExtensionData(model)
                model.ext[:dummy] = data
                @variable(model, x ≥ 0, Bin)
                @variable(model, y ≤ 1, Int)
                @variable(model, z == 0)
                @constraint(model, cref, x + y == 1)

                new_model, reference_map = JuMP.copy(model)
                @test MOIU.mode(JuMP.caching_optimizer(new_model)) == caching_mode
                @test bridge_constraints == (new_model.moibackend isa MOI.Bridges.LazyBridgeOptimizer)
                @test new_model.optimizehook === dummy_optimizer_hook
                @test new_model.ext[:dummy].model === new_model
                x_new = reference_map[x]
                @test x_new.m === new_model
                @test JuMP.name(x_new) == "x"
                y_new = reference_map[y]
                @test y_new.m === new_model
                @test JuMP.name(y_new) == "y"
                z_new = reference_map[z]
                @test z_new.m === new_model
                @test JuMP.name(z_new) == "z"
                @test JuMP.LowerBoundRef(x_new) == reference_map[JuMP.LowerBoundRef(x)]
                @test JuMP.BinaryRef(x_new) == reference_map[JuMP.BinaryRef(x)]
                @test JuMP.UpperBoundRef(y_new) == reference_map[JuMP.UpperBoundRef(y)]
                @test JuMP.IntegerRef(y_new) == reference_map[JuMP.IntegerRef(y)]
                @test JuMP.FixRef(z_new) == reference_map[JuMP.FixRef(z)]
                cref_new = reference_map[cref]
                @test cref_new.m === new_model
                @test JuMP.name(cref_new) == "cref"
            end
        end
    end
    @testset "In Direct mode" begin
        mock = MOIU.MockOptimizer(JuMP.JuMPMOIModel{Float64}())
        model = JuMP.direct_model(mock)
        @test_throws ErrorException JuMP.copy(model)
    end
end
