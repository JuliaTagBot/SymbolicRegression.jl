# Cycle through regularized evolution many times,
# printing the fittest equation every 10% through
function SRCycle(dataset::Dataset{T}, baseline::T, 
        pop::Population,
        ncycles::Int,
        curmaxsize::Int,
        frequencyComplexity::AbstractVector{T};
        verbosity::Int=0,
        options::Options
        )::Population where {T<:Real}

    top = convert(T, 1)
    allT = LinRange(top, convert(T, 0), ncycles)
    for temperature in 1:size(allT)[1]
        if options.annealing
            pop = regEvolCycle(dataset, baseline, pop, allT[temperature], curmaxsize, frequencyComplexity, options)
        else
            pop = regEvolCycle(dataset, baseline, pop, top, curmaxsize, frequencyComplexity, options)
        end

        if verbosity > 0 && (temperature % verbosity == 0)
            bestPops = bestSubPop(pop)
            bestCurScoreIdx = argmin([bestPops.members[member].score for member=1:bestPops.n])
            bestCurScore = bestPops.members[bestCurScoreIdx].score
            debug(verbosity, bestCurScore, " is the score for ", stringTree(bestPops.members[bestCurScoreIdx].tree, options, varMap=dataset.varMap))
        end
    end

    return pop
end
