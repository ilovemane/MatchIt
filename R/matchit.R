matchit <- function(formula, data = NULL, method = "nearest", distance = "glm",
                    link = "logit", distance.options = list(), estimand = "ATT",
                    exact = NULL, mahvars = NULL, antiexact = NULL, discard = "none",
                    reestimate = FALSE, s.weights = NULL, replace = FALSE, m.order = NULL,
                    caliper = NULL, std.caliper = TRUE, ratio = 1, verbose = FALSE,
                    include.obj = FALSE, ...) {

  #Checking input format
  #data input
  mcall <- match.call()

  ## Process method
  if (length(method) == 1 && is.character(method)) {
    method <- tolower(method)
    method <- match_arg(method, c("exact", "cem", "nearest", "optimal", "full", "genetic", "subclass", "cardinality"))
    fn2 <- paste0("matchit2", method)
  }
  else if (is.null(method)) {
    fn2 <- "matchit2null"
  }
  else {
    stop("'method' must be the name of a supported matching method. See ?matchit for allowable options.", call. = FALSE)
  }

  #Process formula and data inputs
  if (!inherits(formula, "formula")) stop("'formula' must be a formula object.", call. = FALSE)

  tt <- terms(formula, data = data)
  if (attr(tt, "response") != 1) stop("A treatment variable must be included on the left-hand side of 'formula'.", call. = FALSE)
  treat.form <- update(tt, . ~ 0)
  treat.mf <- model.frame(treat.form, data = data, na.action = "na.pass")
  treat <- model.response(treat.mf)

  #Check and binarize treat
  treat <- check_treat(treat)
  if (length(treat) == 0) stop("The treatment cannot be NULL.", call. = FALSE)

  names(treat) <- rownames(treat.mf)

  n.obs <- length(treat)

  #Process inputs
  ignored.inputs <- check.inputs(mcall = mcall, method = method, distance = distance, exact = exact,
                                 mahvars = mahvars, antiexact = antiexact, caliper = caliper, discard = discard,
                                 reestimate = reestimate, s.weights = s.weights, replace = replace,
                                 ratio = ratio, m.order = m.order, estimand = estimand)

  if (length(ignored.inputs) > 0) {
    for (i in ignored.inputs) assign(i, NULL)
  }

  #Process replace
  replace <- process.replace(replace, method, ...)

  #Process ratio
  ratio <- process.ratio(ratio, method, ...)

  #Process s.weights
  if (!is.null(s.weights)) {
    if (is.character(s.weights)) {
      if (is.null(data) || !is.data.frame(data)) {
        stop("If 's.weights' is specified a string, a data frame containing the named variable must be supplied to 'data'.", call. = FALSE)
      }
      if (!all(s.weights %in% names(data))) {
        stop("The name supplied to 's.weights' must be a variable in 'data'.", call. = FALSE)
      }
      s.weights.form <- reformulate(s.weights)
      s.weights <- model.frame(s.weights.form, data, na.action = "na.pass")
      if (ncol(s.weights) != 1) stop("'s.weights' can only contain one named variable.", call. = FALSE)
      s.weights <- s.weights[[1]]
    }
    else if (inherits(s.weights, "formula")) {
      s.weights.form <- update(s.weights, NULL ~ .)
      s.weights <- model.frame(s.weights.form, data, na.action = "na.pass")
      if (ncol(s.weights) != 1) stop("'s.weights' can only contain one named variable.", call. = FALSE)
      s.weights <- s.weights[[1]]
    }
    else if (!is.numeric(s.weights)) {
      stop("'s.weights' must be supplied as a numeric vector, string, or one-sided formula.", call. = FALSE)
    }

    if (anyNA(s.weights)) stop("Missing values are not allowed in 's.weights'.", call. = FALSE)
    if (length(s.weights) != n.obs) stop("'s.weights' must be the same length as the treatment vector.", call. = FALSE)

    names(s.weights) <- names(treat)

  }

  #Process distance function
  is.full.mahalanobis <- FALSE
  if (!is.null(method) && method %in% c("exact", "cem", "cardinality")) {
    fn1 <- NULL
  }
  else {
    distance <- process.distance(distance, method, treat)

    if (is.numeric(distance)) {
      fn1 <- "distance2user"
    }
    else if (distance %in% matchit_distances()) {
      fn1 <- "distance2mahalanobis"
      is.full.mahalanobis <- TRUE
      attr(is.full.mahalanobis, "transform") <- distance
    }
    else {
      fn1 <- paste0("distance2", distance)
    }
  }

  #Process exact, mahvars, and antiexact
  exactcovs <- process.variable.input(exact, data)
  exact <- attr(exactcovs, "terms")

  mahcovs <- process.variable.input(mahvars, data)
  mahvars <- attr(mahcovs, "terms")

  antiexactcovs <- process.variable.input(antiexact, data)
  antiexact <- attr(antiexactcovs, "terms")

  #Estimate distance, discard from common support, optionally re-estimate distance
  if (is.null(fn1) || is.full.mahalanobis) {
    #No distance measure
    dist.model <- distance <- link <- NULL
  }
  else if (fn1 == "distance2user") {
    dist.model <- link <- NULL
  }
  else {
    if (verbose) {
      cat("Estimating propensity scores... \n")
    }

    if (!is.null(s.weights)) {
      attr(s.weights, "in_ps") <- !distance %in% c("bart")
    }

    #Estimate distance
    if (is.null(distance.options$formula)) distance.options$formula <- formula
    if (is.null(distance.options$data)) distance.options$data <- data
    if (is.null(distance.options$verbose)) distance.options$verbose <- verbose
    if (is.null(distance.options$estimand)) distance.options$estimand <- estimand
    if (is.null(distance.options$weights) && !fn1 %in% c("distance2bart")) {
      distance.options$weights <- s.weights
    }

    if (!is.null(attr(distance, "link"))) distance.options$link <- attr(distance, "link")
    else distance.options$link <- link

    dist.out <- do.call(fn1, distance.options, quote = TRUE)

    dist.model <- dist.out$model
    distance <- dist.out$distance

    #Remove smoothing terms from gam formula
    if (inherits(dist.model, "gam")) {
      env <- environment(formula)
      formula <- mgcv::interpret.gam(formula)$fake.formula
      environment(formula) <- env
    }
  }

  #Process covs
  covs.formula <- delete.response(terms(formula, data = data))
  covs <- model.frame(covs.formula, data = data, na.action = "na.pass")
  for (i in seq_len(ncol(covs))) {
    if (anyNA(covs[[i]])) stop("Missing values are not allowed in the covariates.", call. = FALSE)
    if (is.character(covs[[i]])) covs[[i]] <- factor(covs[[i]])
    else if (any(!is.finite(covs[[i]]))) stop("Non-finite values are not allowed in the covariates.", call. = FALSE)
  }

  #Process discard
  if (is.null(fn1) || is.full.mahalanobis || fn1 == "distance2user") {
    discarded <- discard(treat, distance, discard)
  }
  else {
    discarded <- discard(treat, dist.out$distance, discard)

    #Optionally reestimate
    if (reestimate && any(discarded)) {
      for (i in seq_along(distance.options)) {
        if (length(distance.options[[i]]) == n.obs) {
          distance.options[[i]] <- distance.options[[i]][!discarded]
        }
        else if (length(dim(distance.options[[i]])) == 2 && nrow(distance.options[[i]]) == n.obs) {
          distance.options[[i]] <- distance.options[[i]][!discarded,,drop = FALSE]
        }
      }
      dist.out <- do.call(fn1, distance.options, quote = TRUE)
      dist.model <- dist.out$model
      distance[!discarded] <- dist.out$distance
    }
  }

  #Process caliper
  calcovs <- NULL

  if (!is.null(caliper)) {
    caliper <- process.caliper(caliper, method, data, covs, mahcovs, distance, discarded, std.caliper)

    if (!is.null(attr(caliper, "cal.formula"))) {
      calcovs <- model.frame(attr(caliper, "cal.formula"), data, na.action = "na.pass")
      if (anyNA(calcovs)) stop("Missing values are not allowed in the covariates named in 'caliper'.", call. = FALSE)
      attr(caliper, "cal.formula") <- NULL
    }
  }

  #Matching!
  match.out <- do.call(fn2, list(treat = treat, covs = covs, data = data, distance = distance,
                                 discarded = discarded, exact = exact, mahvars = mahvars,
                                 replace = replace, m.order = m.order, caliper = caliper,
                                 s.weights = s.weights, ratio = ratio, is.full.mahalanobis = is.full.mahalanobis,
                                 formula = formula, estimand = estimand, verbose = verbose,
                                 antiexact = antiexact, ...),
                       quote = TRUE)

  info <- create_info(method, fn1, link, discard, replace, ratio,
                      mahalanobis = is.full.mahalanobis || !is.null(mahvars),
                      transform = attr(is.full.mahalanobis, "transform"),
                      subclass = match.out$subclass,
                      antiexact = colnames(antiexactcovs),
                      distance_is_matrix = !is.null(distance) && is.matrix(distance))

  #Create X.list for X output, removing duplicate variables
  X.list <- list(covs, exactcovs, mahcovs, calcovs, antiexactcovs)
  all.covs <- lapply(X.list, names)
  for (i in seq_along(X.list)[-1]) if (!is.null(X.list[[i]])) X.list[[i]][names(X.list[[i]]) %in% unlist(all.covs[1:(i-1)])] <- NULL
  X.list[lengths(X.list) == 0] <- NULL

  ## putting all the results together
  out <- list(
    match.matrix = match.out[["match.matrix"]],
    subclass = match.out[["subclass"]],
    weights = match.out[["weights"]],
    X = do.call("cbind", X.list),
    call = mcall,
    info = info,
    estimand = estimand,
    formula = formula,
    treat = treat,
    distance = if (!is.null(distance) && !is.matrix(distance)) setNames(distance, names(treat)),
    discarded = discarded,
    s.weights = s.weights,
    exact = exact,
    mahvars = mahvars,
    caliper = caliper,
    q.cut = match.out[["q.cut"]],
    model = dist.model,
    obj = if (include.obj) match.out[["obj"]]
  )

  out[lengths(out) == 0] <- NULL

  class(out) <- class(match.out)
  return(out)
}
