module SymbolicRegression

# Types
export Population,
    PopMember,
    HallOfFame,
    Options,

    #Functions:
    RunSR,
    SRCycle,
    calculateParetoFrontier,
    countNodes,
    copyNode,
    printTree,
    stringTree,
    evalTreeArray,
    node_to_symbolic,
    symbolic_to_node,
    custom_simplify,
    simplifyWithSymbolicUtils,
    combineOperators,

    #Operators:
    plus,
    sub,
    mult,
    square,
    cube,
    pow,
    div,
    logm,
    logm2,
    logm10,
    sqrtm,
    neg,
    greater,
    relu,
    logical_or,
    logical_and

using Printf: @printf
using Distributed

include("ProgramConstants.jl")
include("Operators.jl")
include("Options.jl")
include("Dataset.jl")
include("Equation.jl")
include("LossFunctions.jl")
include("Utils.jl")
include("EvaluateEquation.jl")
include("MutationFunctions.jl")
include("InterfaceSymbolicUtils.jl")
include("CustomSymbolicUtilsSimplification.jl")
include("SimplifyEquation.jl")
include("PopMember.jl")
include("HallOfFame.jl")
include("CheckConstraints.jl")
include("Mutate.jl")
include("Population.jl")
include("RegularizedEvolution.jl")
include("SingleIteration.jl")
include("ConstantOptimization.jl")

function RunSR(X::AbstractMatrix{T}, y::AbstractVector{T};
        niterations::Int=10,
        weights::Union{AbstractVector{T}, Nothing}=nothing,
        varMap::Union{Array{String, 1}, Nothing}=nothing,
        options::Options=Options()) where {T<:Real}

    testConfiguration(options)

    if size(X)[1] > 10000
        if !options.batching
            println("Note: you are running with more than 10,000 datapoints. You should consider turning on batching (`options.batching`), and also if you need that many datapoints. Unless you have a large amount of noise (in which case you should smooth your dataset first), generally < 10,000 datapoints is enough to find a functional form.")
        end
    end

    dataset = Dataset(X, y,
                     weights=weights,
                     varMap=varMap)

    if dataset.weighted
        avgy = sum(dataset.y .* dataset.weights)/sum(dataset.weights)
        baselineMSE = MSE(dataset.y, ones(T, dataset.n) .* avgy, dataset.weights)
    else
        avgy = sum(dataset.y)/dataset.n
        baselineMSE = MSE(dataset.y, ones(T, dataset.n) .* avgy)
    end

    #TODO - remove this as redundant
    nfeatures = dataset.nfeatures

    # 1. Start a population on every process
    allPops = Future[]
    # Set up a channel to send finished populations back to head node
    channels = [RemoteChannel(1) for j=1:options.npopulations]
    bestSubPops = [Population(dataset, baselineMSE, npop=1, options=options, nfeatures=nfeatures) for j=1:options.npopulations]
    hallOfFame = HallOfFame(options)
    actualMaxsize = options.maxsize + maxdegree
    frequencyComplexity = ones(T, actualMaxsize)
    curmaxsize = 3
    if options.warmupMaxsize == 0
        curmaxsize = options.maxsize
    end

    for i=1:options.npopulations
        future = @spawnat :any Population(dataset, baselineMSE, npop=options.npop, nlength=3, options=options, nfeatures=nfeatures)
        push!(allPops, future)
    end

    # # 2. Start the cycle on every process:
    @sync for i=1:options.npopulations
        @async allPops[i] = @spawnat :any SRCycle(dataset, baselineMSE, fetch(allPops[i]), options.ncyclesperiteration, curmaxsize, copy(frequencyComplexity)/sum(frequencyComplexity), verbosity=options.verbosity, options=options)
    end
    println("Started!")
    cycles_complete = options.npopulations * niterations
    if options.warmupMaxsize != 0
        curmaxsize += 1
        if curmaxsize > options.maxsize
            curmaxsize = options.maxsize
        end
    end

    last_print_time = time()
    num_equations = 0.0
    print_every_n_seconds = 5
    equation_speed = Float32[]

    for i=1:options.npopulations
        # Start listening for each population to finish:
        @async put!(channels[i], fetch(allPops[i]))
    end

    while cycles_complete > 0
        @inbounds for i=1:options.npopulations
            # Non-blocking check if a population is ready:
            if isready(channels[i])
                # Take the fetch operation from the channel since its ready
                cur_pop = take!(channels[i])
                bestSubPops[i] = bestSubPop(cur_pop, topn=options.topn)
                # bestSubPops[i] = bestSubPopParetoDominating(cur_pop, topn=options.topn)

                #Try normal copy...
                bestPops = Population([member for pop in bestSubPops for member in pop.members])

                for member in cur_pop.members
                    size = countNodes(member.tree)
                    frequencyComplexity[size] += 1
                    # println(member, hallOfFame.members[size])
                    actualMaxsize = options.maxsize + maxdegree
                    if size < actualMaxsize && member.score < hallOfFame.members[size].score
                        hallOfFame.members[size] = copyPopMember(member)
                        hallOfFame.exists[size] = true
                    end
                end

                # Dominating pareto curve - must be better than all simpler equations
                dominating = calculateParetoFrontier(dataset, hallOfFame, options)
                open(options.hofFile, "w") do io
                    println(io,"Complexity|MSE|Equation")
                    for member in dominating
                        println(io, "$(countNodes(member.tree))|$(member.score)|$(stringTree(member.tree, options, varMap=dataset.varMap))")
                    end
                end
                cp(options.hofFile, options.hofFile*".bkup", force=true)

                # Try normal copy otherwise.
                if options.migration
                    for k in rand(1:options.npop, round(Int, options.npop*options.fractionReplaced))
                        to_copy = rand(1:size(bestPops.members)[1])
                        cur_pop.members[k] = PopMember(
                            copyNode(bestPops.members[to_copy].tree),
                            bestPops.members[to_copy].score)
                    end
                end

                if options.hofMigration && size(dominating)[1] > 0
                    for k in rand(1:options.npop, round(Int, options.npop*options.fractionReplacedHof))
                        # Copy in case one gets used twice
                        to_copy = rand(1:size(dominating)[1])
                        cur_pop.members[k] = PopMember(
                           copyNode(dominating[to_copy].tree), dominating[to_copy].score
                        )
                    end
                end

                # TODO: Turn off this async when debugging - any errors in this code
                #         are silent.
                # begin
                @async begin
                    allPops[i] = @spawnat :any let
                        tmp_pop = SRCycle(dataset, baselineMSE, cur_pop, options.ncyclesperiteration, curmaxsize, copy(frequencyComplexity)/sum(frequencyComplexity), verbosity=options.verbosity, options=options)
                        @inbounds @simd for j=1:tmp_pop.n
                            tmp_pop.members[j].tree = simplifyTree(tmp_pop.members[j].tree, options)
                            tmp_pop.members[j].tree = combineOperators(tmp_pop.members[j].tree, options)
                            tmp_pop.members[j].tree = simplifyWithSymbolicUtils(tmp_pop.members[j].tree, options)
                            if rand() < 0.1 && options.shouldOptimizeConstants
                                tmp_pop.members[j] = optimizeConstants(dataset, baselineMSE, tmp_pop.members[j], options)
                            end
                        end
                        tmp_pop = finalizeScores(dataset, baselineMSE, tmp_pop, options)
                        tmp_pop
                    end
                    put!(channels[i], fetch(allPops[i]))
                end

                cycles_complete -= 1
                cycles_elapsed = options.npopulations * niterations - cycles_complete
                if options.warmupMaxsize != 0 && cycles_elapsed % options.warmupMaxsize == 0
                    curmaxsize += 1
                    if curmaxsize > options.maxsize
                        curmaxsize = options.maxsize
                    end
                end
                num_equations += options.ncyclesperiteration * options.npop / 10.0
            end
        end
        sleep(1e-3)
        elapsed = time() - last_print_time
        #Update if time has passed, and some new equations generated.
        if elapsed > print_every_n_seconds && num_equations > 0.0
            # Dominating pareto curve - must be better than all simpler equations
            current_speed = num_equations/elapsed
            average_over_m_measurements = 10 #for print_every...=5, this gives 50 second running average
            push!(equation_speed, current_speed)
            if length(equation_speed) > average_over_m_measurements
                deleteat!(equation_speed, 1)
            end
            average_speed = sum(equation_speed)/length(equation_speed)
            curMSE = baselineMSE
            lastMSE = curMSE
            lastComplexity = 0
            if options.verbosity > 0
                @printf("\n")
                @printf("Cycles per second: %.3e\n", round(average_speed, sigdigits=3))
                cycles_elapsed = options.npopulations * niterations - cycles_complete
                @printf("Progress: %d / %d total iterations (%.3f%%)\n", cycles_elapsed, options.npopulations * niterations, 100.0*cycles_elapsed/(options.npopulations*niterations))
                @printf("Hall of Fame:\n")
                @printf("-----------------------------------------\n")
                @printf("%-10s  %-8s   %-8s  %-8s\n", "Complexity", "MSE", "Score", "Equation")
                @printf("%-10d  %-8.3e  %-8.3e  %-.f\n", 0, curMSE, 0f0, avgy)
            end

            #TODO - call pareto function!
            actualMaxsize = options.maxsize + maxdegree
            for size=1:actualMaxsize
                if hallOfFame.exists[size]
                    member = hallOfFame.members[size]
                    curMSE = EvalLoss(member.tree, dataset, options)
                    numberSmallerAndBetter = 0
                    for i=1:(size-1)
                        hofMSE = EvalLoss(hallOfFame.members[i].tree, dataset, options)
                        if (hallOfFame.exists[size] && curMSE > hofMSE)
                            numberSmallerAndBetter += 1
                            break
                        end
                    end
                    betterThanAllSmaller = (numberSmallerAndBetter == 0)
                    if betterThanAllSmaller
                        delta_c = size - lastComplexity
                        delta_l_mse = log(curMSE/lastMSE)
                        score = convert(Float32, -delta_l_mse/delta_c)
                        if options.verbosity > 0
                            @printf("%-10d  %-8.3e  %-8.3e  %-s\n" , size, curMSE, score, stringTree(member.tree, options, varMap=dataset.varMap))
                        end
                        lastMSE = curMSE
                        lastComplexity = size
                    end
                end
            end
            debug(options.verbosity, "")
            last_print_time = time()
            num_equations = 0.0
        end
    end
    return hallOfFame
end

end #module SR
