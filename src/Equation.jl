# Define a serialization format for the symbolic equations:
mutable struct Node
    #Holds operators, variables, constants in a tree
    degree::Int #0 for constant/variable, 1 for cos/sin, 2 for +/* etc.
    constant::Bool #false if variable
    val::CONST_TYPE
    # ------------------- (possibly undefined below)
    feature::Int #Either const value, or enumerates variable.
    op::Int #enumerates operator (separately for degree=1,2)
    l::Node
    r::Node

    Node(val::CONST_TYPE) =                                               new(0, true,                       val                                     ) #Leave other values undefined
    Node(feature::Int) =                                                  new(0, false, convert(CONST_TYPE, 0f0), feature                            )
    Node(op::Int, l::Node) =                                              new(1, false, convert(CONST_TYPE, 0f0),       0,      op,        l         )
    Node(op::Int, l::Union{CONST_TYPE, Int}) =                            new(1, false, convert(CONST_TYPE, 0f0),       0,      op,  Node(l)         )
    Node(op::Int, l::Node, r::Node) =                                     new(2, false, convert(CONST_TYPE, 0f0),       0,      op,        l,       r)
    Node(op::Int, l::Union{CONST_TYPE, Int}, r::Node) =                   new(2, false, convert(CONST_TYPE, 0f0),       0,      op,  Node(l),       r)
    Node(op::Int, l::Node, r::Union{CONST_TYPE, Int}) =                   new(2, false, convert(CONST_TYPE, 0f0),       0,      op,        l, Node(r))
    Node(op::Int, l::Union{CONST_TYPE, Int}, r::Union{CONST_TYPE, Int}) = new(2, false, convert(CONST_TYPE, 0f0),       0,      op,  Node(l), Node(r))
end

# Copy an equation (faster than deepcopy)
function copyNode(tree::Node)::Node
   if tree.degree == 0
       if tree.constant
           return Node(tree.val)
        else
           return Node(tree.feature)
        end
   elseif tree.degree == 1
       return Node(tree.op, copyNode(tree.l))
    else
        return Node(tree.op, copyNode(tree.l), copyNode(tree.r))
   end
end

# Count the operators, constants, variables in an equation
function countNodes(tree::Node)::Int
    if tree.degree == 0
        return 1
    elseif tree.degree == 1
        return 1 + countNodes(tree.l)
    else
        return 1 + countNodes(tree.l) + countNodes(tree.r)
    end
end

# Count the max depth of a tree
function countDepth(tree::Node)::Int
    if tree.degree == 0
        return 1
    elseif tree.degree == 1
        return 1 + countDepth(tree.l)
    else
        return 1 + max(countDepth(tree.l), countDepth(tree.r))
    end
end

function stringOp(op::F, tree::Node, options::Options;
                  bracketed::Bool=false,
                  varMap::Union{Array{String, 1}, Nothing}=nothing)::String where {F}
    if op in [+, -, *, /, ^]
        l = stringTree(tree.l, options, bracketed=false, varMap=varMap)
        r = stringTree(tree.r, options, bracketed=false, varMap=varMap)
        if bracketed
            return "$l $(string(op)) $r"
        else
            return "($l $(string(op)) $r)"
        end
    else
        l = stringTree(tree.l, options, bracketed=true, varMap=varMap)
        r = stringTree(tree.r, options, bracketed=true, varMap=varMap)
        return "$(string(op))($l, $r)"
    end
end

# Convert an equation to a string
function stringTree(tree::Node, options::Options;
                    bracketed::Bool=false,
                    varMap::Union{Array{String, 1}, Nothing}=nothing)::String
    if tree.degree == 0
        if tree.constant
            return string(tree.val)
        else
            if varMap == nothing
                return "x$(tree.feature)"
            else
                return varMap[tree.feature::Int]
            end
        end
    elseif tree.degree == 1
        return "$(options.unaops[tree.op])($(stringTree(tree.l, options, bracketed=true, varMap=varMap)))"
    else
        return stringOp(options.binops[tree.op], tree, options, bracketed=bracketed, varMap=varMap)
    end
end

# Print an equation
function printTree(tree::Node, options::Options; varMap::Union{Array{String, 1}, Nothing}=nothing)
    println(stringTree(tree, options, varMap=varMap))
end

# Return a random node from the tree
function randomNode(tree::Node)::Node
    if tree.degree == 0
        return tree
    end
    a = countNodes(tree)
    b = 0
    c = 0
    if tree.degree >= 1
        b = countNodes(tree.l)
    end
    if tree.degree == 2
        c = countNodes(tree.r)
    end

    i = rand(1:1+b+c)
    if i <= b
        return randomNode(tree.l)
    elseif i == b + 1
        return tree
    end

    return randomNode(tree.r)
end

# Count the number of unary operators in the equation
function countUnaryOperators(tree::Node)::Int
    if tree.degree == 0
        return 0
    elseif tree.degree == 1
        return 1 + countUnaryOperators(tree.l)
    else
        return 0 + countUnaryOperators(tree.l) + countUnaryOperators(tree.r)
    end
end

# Count the number of binary operators in the equation
function countBinaryOperators(tree::Node)::Int
    if tree.degree == 0
        return 0
    elseif tree.degree == 1
        return 0 + countBinaryOperators(tree.l)
    else
        return 1 + countBinaryOperators(tree.l) + countBinaryOperators(tree.r)
    end
end

# Count the number of operators in the equation
function countOperators(tree::Node)::Int
    return countUnaryOperators(tree) + countBinaryOperators(tree)
end


# Count the number of constants in an equation
function countConstants(tree::Node)::Int
    if tree.degree == 0
        if tree.constant
            return 1
        else
            return 0
        end
    elseif tree.degree == 1
        return 0 + countConstants(tree.l)
    else
        return 0 + countConstants(tree.l) + countConstants(tree.r)
    end
end


# Get all the constants from a tree
function getConstants(tree::Node)::AbstractVector{CONST_TYPE}
    if tree.degree == 0
        if tree.constant
            return [tree.val]
        else
            return CONST_TYPE[]
        end
    elseif tree.degree == 1
        return getConstants(tree.l)
    else
        both = [getConstants(tree.l), getConstants(tree.r)]
        return [constant for subtree in both for constant in subtree]
    end
end

# Set all the constants inside a tree
function setConstants(tree::Node, constants::AbstractVector{T}) where {T<:Real}
    if tree.degree == 0
        if tree.constant
            tree.val = convert(CONST_TYPE, constants[1])
        end
    elseif tree.degree == 1
        setConstants(tree.l, constants)
    else
        numberLeft = countConstants(tree.l)
        setConstants(tree.l, constants)
        setConstants(tree.r, constants[numberLeft+1:end])
    end
end
