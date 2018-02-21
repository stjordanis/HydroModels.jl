module HydroModels

# Packages
using JuMP
using StochasticPrograms
using Clp
using RecipesBase
using Parameters
using MacroTools
using MacroTools: postwalk, @q

import MathProgBase.SolverInterface.AbstractMathProgSolver
import MathProgBase.SolverInterface.status
import Plots.font
import Plots.text
import Plots.Shape
import Plots.px

export
    HydroModelData,
    ShortTermModel,
    DayAheadModel,
    initialize!,
    plan!,
    production,
    strategy,
    plants,
    discharge,
    spillage,
    reservoir,
    power,
    revenue,
    totalrevenue,
    singleorder,
    singleorders,
    blockorders,
    independent,
    dependent

JuMPModel = JuMP.Model
JuMPVariable = JuMP.Variable

# Include files
include("data/data.jl")
#include("productionplan.jl")
include("models/model.jl")

# Models
#include("day-ahead/DayAhead.jl")
include("models/short-term/short_term_model.jl")
include("models/day-ahead/DayAhead.jl")

end # module
