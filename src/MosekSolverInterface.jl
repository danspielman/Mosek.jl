module MosekMathProgSolverInterface
using ..Mosek

export MosekSolver


# Known issues: 
#  - SOCP and QP cannot be mixed, but this is not checked (an error from mosek will be produced, though)
#  - Adding a conic quadratic constraint will add an empty constraint to ensure that the number of values 
#    in constraint solution is as expected. The actual constraint solution value is bogus.
#  - Adding rotated conic quadratic constraints will result in a constraint being added, but the constraint soloution
#    for this is pointless. Also, a variable is added, but this is filtered out in the results.
#  - Loading an SOCP problem file will cause some funky problems as information on extra variables etc. is lost.
#  - Dual information is currently useless.
#
#  - The concept of dual values is a bit shaky. Specifically; for a variable x there is a dual for the upper bound, 
#    one for the lower bound and one for the conic "bound". The dual value reported will be (slx-sux+snx).

require(joinpath(Pkg.dir("MathProgBase"),"src","MathProgSolverInterface.jl"))
importall MathProgSolverInterface

MosekMathProgModel_LINR = 0
MosekMathProgModel_QOQP = 1
MosekMathProgModel_SOCP = 2
MosekMathProgModel_SDP  = 3

type MosekMathProgModel <: AbstractMathProgModel 
  task :: Mosek.MSKtask
  numvar :: Int64
end

immutable MosekSolver <: AbstractMathProgSolver
  options
end
MosekSolver(;kwargs...) = MosekSolver(kwargs)

type MosekMathProgModelError
  msg :: String
end

function model(s::MosekSolver)
  # TODO: process solver options
  task = maketask(Mosek.msk_global_env)
  return MosekMathProgModel(task,0)
end

# NOTE: This method will load data into an existing task, but
# it will not necessarily reset all exiting data, depending on the 
# file read (e.g. reading an MPS will not reset parameters)
function loadproblem!(m:: MosekMathProgModel, filename:: String)
  readdata(m.task, filename)
  m.numvar = getnumvar(m.task)
end

function writeproblem(m:: MosekMathProgModel, filename:: String)
  writedata(m.task, filename)
end


function loadproblem!( m::     MosekMathProgModel, 
                      A::     SparseMatrixCSC, 
                      collb:: Array{Float64,1},
                      colub:: Array{Float64,1},
                      obj::   SparseMatrixCSC, 
                      rowlb:: Array{Float64,1}, 
                      rowub:: Array{Float64,1},
                      sense:: Symbol)
  Mosek.deletetask(m.task)
  m.task = maketask(Mosek.msk_global_env)
  
  nrows,ncols = size(A) 
  if ncols != length(collb) ||
     ncols != length(colub) ||
     ncols != size(obj,1)   ||
     nrows != length(rowlb) ||
     nrows != length(rowub) ||
     size(obj,2) != 1
    throw(MosekMathProgModelError("Inconsistent data dimensions"))
  end

  appendvars(m.task, ncols)
  appendcons(m.task, nrows)

  m.numvar = ncols
  
  # input coefficients
  putclist(m.task, obj.rowval, obj.nzval)
  putacolslice(m.task, 1, ncols+1, A.colptr[1:ncols], A.colptr[2:ncols+1], A.rowval, A.nzval)
  setsense!(m, sense)

  # input bounds
  putvarboundslice(m.task, 1, ncols+1, Int32[ MSK_BK_RA for i=1:ncols], collb, colub)
  putconboundslice(m.task, 1, nrows+1, Int32[ MSK_BK_RA for i=1:nrows], rowlb, rowub)
  nothing
end

function loadproblem! ( m::     MosekMathProgModel,
                       A,
                       collb,
                       colub,
                       obj,
                       rowlb,
                       rowub,
                       sense)
  loadproblem!(m,sparse(float(A)),float(collb),float(colub),sparse(float(obj)),float(rowlb),float(rowub),sense)  
end

function getvarLB(m::MosekMathProgModel)
  bkx,blx,bux = getvarboundslice(m.task,1,getnumvar(m))  
  [ (if bkx[i] in [ MSK_BK_FR, MSK_BK_UP ] -Inf else blx[i] end) for i=1:length(bkx) ] :: Array{Float64,1}
end

function complbk(bk,bl)
  if bl > -Inf
    if bk in [ MSK_BK_UP, MSK_BK_RA, MSK_BK_FX ]
      MSK_BK_RA
    else
      MSK_BK_LO
    end
  else
    if bk in [ MSK_BK_UP, MSK_BK_RA, MSK_BK_FX ]
      MSK_BK_UP
    else
      MSK_BK_FR
    end
  end
end

function compubk(bk,bu)
  if bl < Inf
    if bk in [ MSK_BK_LO, MSK_BK_RA, MSK_BK_FX ]
      MSK_BK_RA
    else
      MSK_BK_UP
    end
  else
    if bk in [ MSK_BK_LO, MSK_BK_RA, MSK_BK_FX ]
      MSK_BK_LO
    else
      MSK_BK_FR
    end
  end
end

function setvarLB!(m::MosekMathProgModel, collb)
  nvars = m.numvar
  if nvars != length(collb)
    throw(MosekMathProgModelError("Bound vector has wrong size"))
  end
  bk,bl,bu = getvarboundslice(m.task,1,nvars+1)

  bk = [ complbk(bk[i],collb[i]) for i=1:nvars ]
  putvarbound(m.task, bk, collb, bu)
end

function getvarUB(m::MosekMathProgModel) 
  bkx,blx,bux = getvarboundslice(m.task,1,m.numvar)  
  [ (if bkx[i] in [ MSK_BK_FR, MSK_BK_LO ] Inf else bux[i] end) for i=1:length(bkx) ] :: Array{Float64,1} 
end

function setvarUB!(m::MosekMathProgModel, colub) 
  nvars = m.numvar
  if nvars != length(colub)
    throw(MosekMathProgModelError("Bound vector has wrong size"))
  end
  bk,bl,bu = getvarboundslice(m.task,1,nvars+1)

  bk = [ compubk(bk[i],colub[i]) for i=1:nvars ]
  putvarbound(m.task, bk, bl, colub)
end

function getconstrLB(m::MosekMathProgModel) 
  bkc,blc,buc = getconboundslice(m.task,1,getnumcon(m))  
  [ (if bkc[i] in [ MSK_BK_FR, MSK_BK_UP ] -Inf else blc[i] end) for i=1:length(bkc) ] :: Array{Float64,1}
end

function setconstrLB!(m::MosekMathProgModel, rowlb) 
  nvars = getnumcon(m.task)
  if ncons != length(rowlb)
    throw(MosekMathProgModelError("Bound vector has wrong size"))
  end
  bk,bl,bu = getconboundslice(m.task,1,ncons+1)

  bk = [ complbk(bk[i],rowlb[i]) for i=1:ncons ]
  putconbound(m.task, bk, rowlb, bu)
end

function getconstrUB(m::MosekMathProgModel) 
  bkc,blc,buc = getconboundslice(m.task,1,getnumcon(m))  
  [ (if bkc[i] in [ MSK_BK_FR, MSK_BK_LO ] Inf else buc[i] end) for i=1:length(bkc) ] :: Array{Float64,1} 
end

function setconstrUB!(m::MosekMathProgModel, rowub) 
  nvars = getnumcon(m.task)
  if ncons != length(rowub)
    throw(MosekMathProgModelError("Bound vector has wrong size"))
  end
  bk,bl,bu = getconboundslice(m.task,1,ncons+1)

  bk = [ compubk(bk[i],rowub[i]) for i=1:ncons ]
  putconbound(m.task, bk, rowub, bu)
end

function getobj(m::MosekMathProgModel) 
  getc(m.task)
end

function setobj!(m::MosekMathProgModel, obj::Array{Float64,1})     
  nvars = m.numvar
  if size(obj,1) != nvars
    throw(MosekMathProgModelError("Objective vector has wrong size"))
  end

  putclist(m.task,[1:numvar+1],obj)
end

function setobj!(m::MosekMathProgModel, obj)
  setobj(m,dense(float(obj)))
end

# addvar(m::MosekMathProgModel, rowidx, rowcoef, collb, colub, objcoef)
# addconstr(m::MosekMathProgModel, colidx, colcoef, rowlb, rowub) 

updatemodel!(m::MosekMathProgModel) = nothing

function setsense!(m::MosekMathProgModel,sense) 
  if     sense == :Min
    putobjsense(m.task, MSK_OBJECTIVE_SENSE_MINIMIZE)
  elseif sense == :Max
    putobjsense(m.task, MSK_OBJECTIVE_SENSE_MAXIMIZE)
  else
   throw(MosekMathProgModelError("Invalid objective sense"))
  end
  nothing  
end

function getsense(m::MosekMathProgModel) 
  sense = getobjsense(m.task)
  if sense == MSK_OBJECTIVE_SENSE_MINIMIZE
    :Min
  elseif sense == MSK_OBJECTIVE_SENSE_MAXIMIZE
    :Max
  else
    None
  end
end

numvar(m::MosekMathProgModel) = m.numvar
numconstr(m::MosekMathProgModel) = getnumcon(m.task)
#optimize!(m::MosekMathProgModel) = optimize(m.task)
function optimize!(m::MosekMathProgModel)  optimize(m.task); writedata(m.task,"mskprob.opf") end





function getsoldef(m::MosekMathProgModel)
  if solutiondef(m.task,MSK_SOL_ITG) MSK_SOL_ITG
  elseif solutiondef(m.task,MSK_SOL_BAS) MSK_SOL_BAS
  elseif solutiondef(m.task,MSK_SOL_ITR) MSK_SOL_ITR
  else -1
  end
end

# NOTE: What are the 'legal' values to return?
# Another NOTE: status seems to mash together the problem status, 
# the solution status and the solver status. I'll try to cope 
# in some sensible manner.
function status(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 return :Unknown end  
  prosta = getprosta(m.task,soldef)
  solsta = getsolsta(m.task,soldef)

  if     solsta == MSK_SOL_STA_UNKNOWN
    :Unknown
  elseif solsta == MSK_SOL_STA_DUAL_FEAS ||
         solsta == MSK_SOL_STA_PRIM_FEAS ||
         solsta == MSK_SOL_STA_NEAR_PRIM_FEAS ||
         solsta == MSK_SOL_STA_NEAR_DUAL_FEAS ||
         solsta == MSK_SOL_STA_PRIM_AND_DUAL_FEAS ||
         solsta == MSK_SOL_STA_NEAR_PRIM_AND_DUAL_FEAS 
    :Unknown
  elseif solsta == MSK_SOL_STA_DUAL_INFEAS_CER ||
         solsta == MSK_SOL_STA_NEAR_DUAL_INFEAS_CER
    :Unbounded
  elseif solsta == MSK_SOL_STA_PRIM_INFEAS_CER ||
         solsta == MSK_SOL_STA_NEAR_PRIM_INFEAS_CER
    :Infeasible
  elseif solsta == MSK_SOL_STA_OPTIMAL ||
         solsta == MSK_SOL_STA_NEAR_OPTIMAL ||
         solsta == MSK_SOL_STA_INTEGER_OPTIMAL ||
         solsta == MSK_SOL_STA_NEAR_INTEGER_OPTIMAL
    :Optimal
  else
    error("Internal value error")
  end
end

function getobjval(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 return NaN end

  getprimalobj(m.task,soldef)
end

# NOTE: I am not entirely sure how to implement this... If the solution status 
# is feasible for an integer problem, then the objective value is the best 
# known bound.
getobjbound(m::MosekMathProgModel) = getdouinf(m.task,MSK_DINF_MIO_OBJ_BOUND)

function getsolution(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) 
  end
  solsta = getsolsta(m.task,soldef)
  if solsta in [ MSK_SOL_STA_OPTIMAL, MSK_SOL_STA_PRIM_FEAS, MSK_SOL_STA_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_NEAR_OPTIMAL, MSK_SOL_STA_NEAR_PRIM_FEAS, MSK_SOL_STA_NEAR_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_INTEGER_OPTIMAL, MSK_SOL_STA_NEAR_INTEGER_OPTIMAL ]
    getxxslice(m.task,soldef,1,m.numvar+1)
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end

function getconstrsolution(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) end
  solsta = getsolsta(m.task,soldef)
  if solsta in [ MSK_SOL_STA_OPTIMAL, MSK_SOL_STA_PRIM_FEAS, MSK_SOL_STA_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_NEAR_OPTIMAL, MSK_SOL_STA_NEAR_PRIM_FEAS, MSK_SOL_STA_NEAR_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_INTEGER_OPTIMAL, MSK_SOL_STA_NEAR_INTEGER_OPTIMAL ]
    getxc(m.task,soldef)
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end

# NOTE: is the dual in your model slx-sux or sux-slx?
function getreducedcosts(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) end
  solsta = getsolsta(m.task,soldef)

  if solsta in [ MSK_SOL_STA_OPTIMAL, MSK_SOL_STA_DUAL_FEAS, MSK_SOL_STA_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_NEAR_OPTIMAL, MSK_SOL_STA_NEAR_DUAL_FEAS, MSK_SOL_STA_NEAR_PRIM_AND_DUAL_FEAS ]
    if soldef == MSK_SOL_ITR
      getsuxslice(m.task,soldef,1,m.numvar+1) - getslxslice(m.task,soldef,1,m.numvar+1) + getsnxslice(m.task,soldef,1,m.numvar+1)
    else
      getsuxslice(m.task,soldef,1,m.numvar+1) - getslxslice(m.task,soldef,1,m.numvar+1)
    end
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end

function getconstrduals(m::MosekMathProgModel)
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) end
  solsta = getsolsta(m.task,soldef)
  if solsta in [ MSK_SOL_STA_OPTIMAL, MSK_SOL_STA_DUAL_FEAS, MSK_SOL_STA_PRIM_AND_DUAL_FEAS, MSK_SOL_STA_NEAR_OPTIMAL, MSK_SOL_STA_NEAR_DUAL_FEAS, MSK_SOL_STA_NEAR_PRIM_AND_DUAL_FEAS ]
    gety(m.task,soldef)
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end

function getinfeasibilityray(m::MosekMathProgModel) 
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) end
  solsta = getsolsta(m.task,soldef)
  if solsta in [ MSK_SOL_STA_PRIM_INFEAS_CER, MSK_SOL_STA_NEAR_PRIM_INFEAS_CER ]
    if soldef == MSK_SOL_ITR
      getsuxslice(m.task,soldef,1,m.numvar+1) - getslxslice(m.task,soldef,1,m.numvar+1) + getsnxslice(m.task,soldef,1,m.numvar+1)
    else
      getsuxslice(m.task,soldef,1,m.numvar+1) - getslxslice(m.task,soldef,1,m.numvar+1)
    end
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end

function getunboundedray(m::MosekMathProgModel)
  soldef = getsoldef(m)
  if soldef < 0 throw(MosekMathProgModelError("No solution available")) end
  solsta = getsolsta(m.task,soldef)
  if solsta in [ MSK_SOL_STA_DUAL_INFEAS_CER, MSK_SOL_STA_NEAR_DUAL_INFEAS_CER ]
    getxxslice(m.task,soldef,1,m.numvar+1)
  else
    throw(MosekMathProgModelError("No solution available")) 
  end
end



getrawsolver(m::MosekMathProgModel) = m.task

function setvartype!(m::MosekMathProgModel, vartype :: Array{Char,1}) 
  numvar = getnumvar(m.task)
  n = min(length(vartype),numvar)
  putvartypelist(m.task,[1:n],convert(Array{Int32},[ (if c == 'I' MSK_VAR_TYPE_INT else MSK_VAR_TYPE_CONT end) for c=vartype ]))
end

function getvartype(m::MosekMathProgModel) 
  numvar = getnumvar(m.task)
  vtlist = getvartypelist(m.task,[1:numvar])
  [ if vt == MSK_VAR_TYPE_CONT 'I' else 'C' end for vt=vtlist ] :: Array{Char,1}
end

# QCQO interface, so far only non-conic.

function setquadobj!(m::MosekMathProgModel, rowidx,colidx,quadval)
  qosubi = copy(rowidx)
  qosubj = copy(colidx)
  qoval  = copy(quadval)
  for i=1:length(rowidx)
    if qosubj[i] > qosubi[i]
      cj = qosubj[i]
      qosubj[i] = qosubi[i]
      qosubi[i] = cj
    end
  end
  putqobj(m.task,qosubi,qosubj,convert(Array{Float64},qoval))
end


# Note: 
#  If the quadratic terms define a quadratic cone, the linear terms, sense and rhs are ignored.
function addquadconstr!(m::MosekMathProgModel, linearidx, linearval, quadrowidx, quadcolidx, quadval, sense, rhs) 
  subj = linearidx
  valj = linearval
  qcksubi = copy(quadrowidx)
  qcksubj = copy(quadcolidx)
  qckval  = quadval

  # detect SOCP form

  ct,x = 
    begin
      let num_posonediag = 0, 
          offdiag_idx    = 0, 
          negdiag_idx    = 0
        for i=1:length(qcksubi) 
          if qcksubi[i] == qcksubj[i] 
            if abs(qckval[i]-1.0) < 1e-12 
              num_posonediag += 1 
            elseif abs(qckval[i]+1.0) < 1e-12 
              negdiag_idx = i
            end
          elseif qcksubi[i] != qcksubj[i]
            if abs(qckval[i]+1.0) < 1e-12 
              offdiag_idx = i 
            end
          end
        end
        
        if num_posonediag == length(qcksubj)-1 && negdiag_idx > 0
          x = Array(Int64,length(qcksubj))
          x[1] = qcksubj[negdiag_idx]
          for i=1:negdiag_idx-1 x[i+1] = qcksubj[i] end
          for i=negdiag_idx+1:length(qcksubj) x[i] = qcksubj[i] end

          MSK_CT_QUAD, x
        elseif num_posonediag == length(qcksubj)-2 && offdiag_idx > 0
          x = Array(Int64,length(qcksubj))
          x[1] = qcksubi[offdiag_idx]
          x[2] = qcksubj[offdiag_idx]
          for i=1:offdiag_idx-1 x[i+2] = qcksubj[i] end
          for i=offdiag_idx+1:length(qcksubj) x[i+1] = qcksubj[i] end

          MSK_CT_RQUAD, x
        else
          -1,()
        end
      end
    end

  if     ct == MSK_CT_QUAD
    appendcone(m.task, ct, 0.0, x)
    appendcons(m.task,1)
  elseif ct == MSK_CT_RQUAD
    appendvars(m.task,1) # create variable z
    appendcons(m.task,1)
    nvar  = getnumvar(m.task)
    ncon  = getnumcon(m.task)
    z     = nvar
    
    # set z = 1/2 x0
    putarow(m.task, ncon, [ x[1], z ], [ 1.0, -1.0])
    putvarbound(m.task, z, MSK_BK_FR, 0.0, 0.0)
    putconbound(m.task, ncon, MSK_BK_FX, 0.0, 0.0)

    # create cone 2*z*x1 > sum_(i=2) xi^2
    x[1] = z
    appendcone(m.task, ct, 0.0, x)
  else
    for i=1:length(quadrowidx)
      if qcksubj[i] > qcksubi[i]
        cj = qcksubj[i]
        qcksubj[i] = qcksubi[i]
        qcksubi[i] = cj
      elseif qcksubj[i] == qcksubi[i]
        qckval[i] = qckval[i] * 2
      end
    end

    k = getnumcon(m.task)+1
    appendcons(m.task,1)

    putarow(m.task, k, convert(Array{Float64},subj), convert(Array{Float64},valj))
    putqconk(m.task,k, qcksubi,qcksubj,qckval)

    if sense == '<'
      putconbound(m.task,k,MSK_BK_UP, -Inf,convert(Float64,rhs))
    elseif sense == '>'
      putconbound(m.task,k,MSK_BK_LO, convert(Float64,rhs),Inf)
    else
      putconbound(m.task,k,MSK_BK_FR, -Inf,Inf)
    end
  end
end

end


