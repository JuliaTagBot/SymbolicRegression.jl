using Printf: @printf

function id(x::T)::T where {T<:Real}
    x
end

function debug(verbosity, string...)
    if verbosity > 0
        println(string...)
    end
end

function getTime()::Int
    return round(Int, 1e3*(time()-1.6e9))
end


# Check for errors before they happen
function testConfiguration(options::Options)
    test_input = LinRange(-100f0, 100f0, 99)

    try
        for left in test_input
            for right in test_input
                for binop in options.binops
                    test_output = binop.(left, right)
                end
            end
            for unaop in options.unaops
                test_output = unaop.(left)
            end
        end
    catch error
        @printf("\n\nYour configuration is invalid - one of your operators is not well-defined over the real line.\n\n\n")
        throw(error)
    end

    for binop in options.binops
        if binop in options.unaops
            @printf("\n\nYour configuration is invalid - one operator appears in both the binary operators and unary operators.\n\n\n")
        end
    end
end

