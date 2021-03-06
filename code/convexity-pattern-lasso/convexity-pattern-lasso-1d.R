################################################################################
# 
# 1-D Convexity Pattern Regression as Lasso
# (using Sabyasachi's new formulation)
# 
# Professor John Lafferty's Group
# YJ Choe
# The University of Chicago
#
# ------------------------------------------------------------------------------
#
# Version 1.0: August 5, 2014
# - A working version of the 1-D convexity pattern regression
#   formulated as a convex program (QP) with a single parameter lambda.
#   The "magic" here is to use Sabyasachi's idea to bound the sum of 
#   differences between neighboring subgradients for both components.
#   In particular, we don't have any integer variables here.
#   In practice, the output is very sensitive to the choice of lambda,
#   which we think a simple algorithm can "automatically" choose. 
#
# Version 1.1: August 5, 2014
# - Added a wrapper function that chooses lambda automatically.
#   The behavior is not always stable, however, and it occasionally fails.
#   This is likely due to the fact that the original convex program does not
#   always seem to find the optimal solution. 
# - Note that this is possible only due to the conjectured lasso-like behavior
#   of the difference in subgradients: we start from lambda = 0, and
#   increase lambda until the other component becomes nontrivial. We then
#   take the fit from the previous iteration.
#
# Version 1.2: August 11, 2014
# - Moved the lasso-like constraint to the objective function. Now,
#   the behavior of lambda is more like lasso: greater lambda means
#   more regularization, and for large lambda the fit is identically zero.
#   Note that the lambda=0 fit is always a sum of convex and concave
#   components with MSE~0, because in 1-D, with identifiability constraints,
#   any sequence can be expressed as a sum of a convex sequence and 
#   a concave sequence.
# - Made according changes to the auto function. It now has step size 0.01
#   and chooses the optimal lambda quite nicely. 
# - For a demo, try example.1d.auto(). 
#   Also see ./convexity-pattern-cvx-backfit.R and run example() there
#   for the multivariate backfitting version.
#
# Version 1.3: August 14, 2014
# - Fixed the objective to be the mean squared error instead of
#   the square root of it. The 1/n factor is now also there.
#   Previously there was an issue with Rmosek rotated cones that 
#   somehow prevented doing this.
# - Renamed the function to be convexity.pattern.lasso.1d() and the filename
#   to be convexity-pattern-lasso-1d.R.
# - Removed the automatic choice function, as it does not find sparse patterns.
#   It is replaced with choose.first.lambda(), which chooses the smallest lambda
#   that yields a valid pattern: one without any component that has both convex
#   and concave components active. One can use this function to find the lower
#   bound on lambda, and choose some larger lambda for intended sparsity.
# 
# ** Please feel free to improve the code and leave a note here. **
#
################################################################################

convexity.pattern.lasso.1d = function (x, y, lambda = 0.1) {
  
  ########################################
  #
  # 1-D convexity pattern regression function
  # as a convex program.
  #
  # [Inputs]
  # x: n-vector (covariates)
  # y: n-vector (SCALED outcomes)
  # lambda: positive scalar (sparsity&smoothness parameter)
  #
  # [Output]
  # a list consisting of...
  #   $status: program and solution statuses
  #            as given by Rmosek
  #   $pattern: a Boolean pair indicating
  #             whether each component is active
  #             (convex, concave)
  #   $fit: an n-vector from the component
  #   $f: an n-vector from the convex component
  #   $g: an n-vector from the concave component
  #   $MSE: mean squared error
  #   $r: raw output from Rmosek solver
  #
  ########################################

  #---------------------------------------
  # Setup
  #---------------------------------------

  # Import Rmosek
  if (!require("Rmosek")) {
    stop ("Rmosek not installed.")
  }

  # Program size
  n = length(x) # number of points
  
  # Sort the points and keep the order
  ord = order(x)
  x = x[ord]
  y = y[ord]

  #---------------------------------------
  # Rmosek Conic QP
  #---------------------------------------

  # Helper function: Accessing the last element of a sequence
  last = function (x) {
    # x is a sequence
    return (x[length(x)])
  }

  # [Program variables]
  # Number of variables: 5n - 1
  # "Effective" number of variables: 2n + 1
  # Number of integer variables: 0 (convex program)
  # For i = 1, ..., n and j = 1, ..., p,
  # fitted values: f_i, g_i 
  # pointwise errors (auxiliary): r_i
  # slopes for convexity (auxiliary): beta_i, gamma_i (i up to n-1)
  # RQUAD constant 1/2: s
  # objective replacement: t
  f.index = seq(1, n)
  g.index = last(f.index) + seq(1, n) 
  r.index = last(g.index) + seq(1, n) 
  beta.index = last(r.index) + seq(1, n-1)
  gamma.index = last(beta.index) + seq(1, n-1)
  s.index = last(gamma.index) + 1
  t.index = last(s.index) + 1 
  num.vars = t.index

  # Set up the program
  convexity.pattern = list(sense = "min")

  # Objective: (1/n) * t + lambda * (beta_{n-1} - beta_1 - gamma_{n-1} + gamma_1)
  # where t = sum((y_i - (f_i + g_i))^2)
  # Note that MSE = (1/n) * t.
  convexity.pattern$c = c(rep(0, last(r.index)), 
                          -lambda, rep(0, n-3), lambda,
                          lambda, rep(0, n-3), -lambda,
                          0, 1/n)

  # Affine constraint 1: auxiliary variables [no cost]
  # r_i = y_i - (f_i + g_i), that is
  # f_i + g_i + r_i = y_i
  
  # number of rows (affine contraints)
  n1 = n
  
  A1 = Matrix(0, nrow = n1, ncol = num.vars)
  A1[, f.index] = .sparseDiagonal(n1)
  A1[, g.index] = .sparseDiagonal(n1)
  A1[, r.index] = .sparseDiagonal(n1)

  # Affine constraint 2: convexity 
  # [2*(n-1) affine no-cost equalities, 2*(n-2) affine inequalities]
  # For sorted points x_i, 
  # part 1: (i = 1, ..., n-1)
  # f_{i+1} - f_i = beta_i * (x_{i+1} - x_i)
  # g_{i+1} - g_i = gamma_i * (x_{i+1} - x_i)
  # part 2: (i = 1, ..., n-2)
  # beta_i <= beta_{i+1}
  # gamma_i >= gamma_{i+1}
  
  # number of rows (affine contraints)
  n2.part1 = 2*(n-1)
  n2.part2 = 2*(n-2)
  n2 = n2.part1 + n2.part2
  
  A2 = Matrix(0, nrow = n2, ncol = num.vars)
    
  # part 1
  diag.f = bandSparse(n-1, n, c(0, 1), list(rep(-1, n-1), rep(1, n-1)))
  diag.g = diag.f
  diag.beta = .sparseDiagonal(n-1, x[2:n] - x[1:(n-1)])
  diag.gamma = diag.beta
    
  rows.f = seq(1, n-1)
  rows.g = (n-1) + seq(1, n-1)

  A2[rows.f, f.index] = diag.f
  A2[rows.f, beta.index] = -diag.beta
  A2[rows.g, g.index] = diag.g
  A2[rows.g, gamma.index] = -diag.gamma
    
  # part 2
  diag2.beta = bandSparse(n-2, n-1, c(0, 1), list(rep(-1, n-2), rep(1, n-2)))
  diag2.gamma = -diag2.beta
  
  rows.beta = 2*(n-1) + seq(1, n-2)
  rows.gamma = 2*(n-1) + (n-2) + seq(1, n-2)
  A2[rows.beta, beta.index] = diag2.beta
  A2[rows.gamma, gamma.index] = diag2.gamma

  # Affine constraint 3: identifiability constraints [4 equalities]
  # We want the fitted values of each component to be centered
  # and also orthogonal to the data vector x. (inner product = 0)
  # This eliminates the subspace of vectors that are both convex and concave.
  
  # number of rows (affine contraints)
  n3 = 4

  A3 = Matrix(0, nrow = n3, ncol = num.vars)
  A3[1, f.index] = rep(1, n)
  A3[2, g.index] = rep(1, n)
  A3[3, f.index] = x
  A3[4, g.index] = x
  
  # Affine constraint 4: auxiliary variable for Rmosek rotated cone [no cost]
  # s = 1/2 
  
  # number of rows (affine contraints)
  n4 = 1
  
  A4 = Matrix(0, nrow = n4, ncol = num.vars)
  A4[, s.index] = 1

  # Affine constraints combined with bounds
  convexity.pattern$A = rBind(A1, A2, A3, A4)
  convexity.pattern$bc = rbind(
    blc = c(y, 
            rep(0, n2.part1), rep(0, n2.part2), 
            rep(0, n3),
            rep(1/2, n4)),
    buc = c(y, 
            rep(0, n2.part1), rep(Inf, n2.part2), 
            rep(0, n3),
            rep(1/2, n4)) 
  )

  # Constraints on the program variables
  convexity.pattern$bx = rbind(
    blx = c(rep(-Inf, length(c(f.index, g.index))),
            rep(-Inf, length(r.index)),
            rep(-Inf, length(c(beta.index, gamma.index))), 
            0, # s
            0), # t
    bux = c(rep(Inf, length(c(f.index, g.index))),
            rep(Inf, length(r.index)),
            rep(Inf, length(c(beta.index, gamma.index))),
            Inf, # s
            Inf) # t
  )

  # Conic constraint: quadratic objective (mean squared error)
  # Note: In Rmosek terms, this is 2*t*s >= sum(r^2)
  #       where s = 1/2. 
  convexity.pattern$cones = cbind(list("RQUAD", c(t.index, s.index, r.index)))

  # Solve the program using Rmosek!
  r = mosek(convexity.pattern, opts = list(verbose = 1))

  #---------------------------------------
  # Results
  #---------------------------------------

  # Outputs
  status = list(
    solution = r$sol$itr$solsta, 
    program = r$sol$itr$prosta
  )
  output = r$sol$itr$xx

  # helper: check if the fit is "essentially" zero
  is.zero = function (fit, tol = 1e-4) {
    return (max(abs(fit)) < n*tol)
  }
  # helper: returns the pattern matrix
  get.pattern = function(f, g) {
    p = matrix(as.integer(c(!is.zero(f), !is.zero(g))), nrow = 2)
    rownames(p) = c("convex", "concave")
    colnames(p) = c("pattern")
    return (p)
  }

  f = output[f.index][invPerm(ord)]
  g = output[g.index][invPerm(ord)]
  pattern = get.pattern(f, g)
  MSE = (1/n) * output[t.index]

  fit = rep(0, n)
  if (pattern["convex",]) {
    fit = f
  } else if (pattern["concave",]) {
    fit = g
  }
  
  return (list(status = status,
               pattern = pattern,
               fit = fit,
               f = f,
               g = g,
               MSE = MSE,
               r = r))
}

example.1d = function (n = 100, sigma = 1, lambda = 0.05) {

  ########################################
  # Testing the univariate convexity
  # pattern regression function.
  ########################################

  # Generate Synthetic Data
  # True convex function: f(x) = x^4 + 2x (then scaled)
  f = function (x) { x^4 + 2*x }
  x = runif(n, -5, 5)
  # Resample if any two points are too close.
  while (min(dist(x)) < 1e-6) {
    x = runif(n, -5, 5)
  }
  epsilon = rnorm(n, 0, sigma) # Gaussian noise
  f.val = scale(f(x))
  y = f.val + epsilon
  
  result = convexity.pattern.lasso.1d(x, y, lambda)
  
  par(mfrow = c(1,1))
  plot(x, y, main = "1-D Convexity Pattern Regression as Lasso")
  ord = order(x)
  lines(x[ord], f.val[ord], lwd = 2, col = "darkgray")
  lines(x[ord], result$f[ord], lwd = 2, col = "red")
  lines(x[ord], result$g[ord], lwd = 2, col = "blue")
  points(x, result$fit, pch = 20, col = "purple")
  mtext(paste(result$status$solution, ", ", result$status$program, sep=""), 
        side = 3, adj = 0)
  mtext(sprintf("N: %d, lambda: %.2f, MSE: %.2f", n, lambda, result$MSE), 
        side = 3, adj = 1)
  
  print(list(pattern = result$pattern))
}

choose.first.lambda = function (x, y, step = 0.01, max.step = 100) {
  
  ########################################
  #
  # This function chooses the smallest lambda
  # that is "valid", i.e. each component is either
  # convex or concave -- but not both -- or zero.
  #
  # Note that 'step' is simply the desired accuracy
  # of the lambda parameter. 'max.step' is
  # any large integer. 
  #
  # [Inputs]
  # x: n-vector (covariates)
  # y: n-vector (SCALED outcomes)
  # step: desired accuracy of lambda
  # max.step: maximum number of iterations
  #
  # [Output]
  # a list consisting of...
  #   $lambda: the optimal lambda
  #   $status: program and solution statuses
  #            as given by Rmosek
  #   $pattern: a Boolean pair indicating
  #             whether each component is active
  #             (convex, concave)
  #   $fit: an n-vector from the component
  #   $f: an n-vector from the convex component
  #   $g: an n-vector from the concave component
  #   $MSE: mean squared error
  #   $r: raw output from Rmosek solver
  #
  ########################################
  
  # iterate until the best fit with exactly one component active
  # (i.e. stop right before both components are active)
  result = convexity.pattern.lasso.1d(x, y, 0)
  for (lambda in step * seq(1, max.step)) {

    result = convexity.pattern.lasso.1d(x, y, lambda)

    if (sum(result$pattern) == 1) {
      break
    }
    if (sum(result$pattern) == 0) {
    	cat ("Warning: Did not find a convex or concave component.")
    	break
    }
    if (lambda == step * max.step) {
    	cat ("Warning: Reached maximum step before convergence.")
    }
  }
  
  result$lambda = lambda
  return (result)
}
