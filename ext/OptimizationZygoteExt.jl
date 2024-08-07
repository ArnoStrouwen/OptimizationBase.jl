module OptimizationZygoteExt

using OptimizationBase, SparseArrays
using OptimizationBase.FastClosures
import OptimizationBase.ArrayInterface
import OptimizationBase.SciMLBase: OptimizationFunction
import OptimizationBase.LinearAlgebra: I, dot
import DifferentiationInterface
import DifferentiationInterface: prepare_gradient, prepare_hessian, prepare_hvp,
                                 prepare_jacobian,
                                 gradient!, hessian!, hvp!, jacobian!, gradient, hessian,
                                 hvp, jacobian
using ADTypes, SciMLBase
import Zygote

function OptimizationBase.instantiate_function(
        f::OptimizationFunction{true}, x, adtype::ADTypes.AutoZygote,
        p = SciMLBase.NullParameters(), num_cons = 0;
        fg = false, fgh = false, cons_vjp = false, cons_jvp = false)
    function _f(θ)
        return f(θ, p)[1]
    end

    adtype, soadtype = OptimizationBase.generate_adtype(adtype)

    if f.grad === nothing
        extras_grad = prepare_gradient(_f, adtype, x)
        function grad(res, θ)
            gradient!(_f, res, adtype, θ, extras_grad)
        end
    else
        grad = (G, θ) -> f.grad(G, θ, p)
    end

    if fg == true
        function fg!(res, θ)
            (y, _) = value_and_gradient!(_f, res, adtype, θ, extras_grad)
            return y
        end
    end

    hess_sparsity = f.hess_prototype
    hess_colors = f.hess_colorvec
    if f.hess === nothing
        extras_hess = prepare_hessian(_f, soadtype, x)
        function hess(res, θ)
            hessian!(_f, res, soadtype, θ, extras_hess)
        end
    else
        hess = (H, θ) -> f.hess(H, θ, p)
    end

    if fgh == true
        function fgh!(G, H, θ)
            (y, _, _) = value_derivative_and_second_derivative!(_f, G, H, θ, extras_hess)
            return y
        end
    end

    if f.hv === nothing
        extras_hvp = prepare_hvp(_f, soadtype, x, zeros(eltype(x), size(x)))
        hv = function (H, θ, v)
            hvp!(_f, H, soadtype, θ, v, extras_hvp)
        end
    else
        hv = f.hv
    end

    if f.cons === nothing
        cons = nothing
    else
        function cons(res, θ)
            return f.cons(res, θ, p)
        end

        function cons_oop(x)
            _res = Zygote.Buffer(x, num_cons)
            cons(_res, x)
            return copy(_res)
        end
    end

    cons_jac_prototype = f.cons_jac_prototype
    cons_jac_colorvec = f.cons_jac_colorvec
    if cons !== nothing && f.cons_j === nothing
        extras_jac = prepare_jacobian(cons_oop, adtype, x)
        function cons_j(J, θ)
            jacobian!(cons_oop, J, adtype, θ, extras_jac)
            if size(J, 1) == 1
                J = vec(J)
            end
        end
    else
        cons_j = (J, θ) -> f.cons_j(J, θ, p)
    end

    if f.cons_vjp === nothing && cons_vjp == true
        extras_pullback = prepare_pullback(cons_oop, adtype, x)
        function cons_vjp!(J, θ, v)
            pullback!(cons_oop, J, adtype, θ, v, extras_pullback)
        end
    else
        cons_vjp! = nothing
    end

    if f.cons_jvp === nothing && cons_jvp == true
        extras_pushforward = prepare_pushforward(cons_oop, adtype, x)
        function cons_jvp!(J, θ, v)
            pushforward!(cons_oop, J, adtype, θ, v, extras_pushforward)
        end
    else
        cons_jvp! = nothing
    end

    conshess_sparsity = f.cons_hess_prototype
    conshess_colors = f.cons_hess_colorvec
    if cons !== nothing && f.cons_h === nothing
        fncs = [(x) -> cons_oop(x)[i] for i in 1:num_cons]
        extras_cons_hess = prepare_hessian.(fncs, Ref(soadtype), Ref(x))

        function cons_h(H, θ)
            for i in 1:num_cons
                hessian!(fncs[i], H[i], soadtype, θ, extras_cons_hess[i])
            end
        end
    else
        cons_h = (res, θ) -> f.cons_h(res, θ, p)
    end

    function lagrangian(x, σ = one(eltype(x)), λ = ones(eltype(x), num_cons))
        return σ * _f(x) + dot(λ, cons_oop(x))
    end

    lag_hess_prototype = f.lag_hess_prototype

    if f.lag_h === nothing
        lag_extras = prepare_hessian(lagrangian, soadtype, x)
        lag_hess_prototype = zeros(Bool, length(x), length(x))

        function lag_h(H::AbstractMatrix, θ, σ, λ)
            if σ == zero(eltype(θ))
                cons_h(H, θ)
                H *= λ
            else
                hessian!(x -> lagrangian(x, σ, λ), H, soadtype, θ, lag_extras)
            end
        end

        function lag_h(h, θ, σ, λ)
            H = eltype(θ).(lag_hess_prototype)
            hessian!(x -> lagrangian(x, σ, λ), H, soadtype, θ, lag_extras)
            k = 0
            rows, cols, _ = findnz(H)
            for (i, j) in zip(rows, cols)
                if i <= j
                    k += 1
                    h[k] = H[i, j]
                end
            end
        end
    else
        lag_h = (res, θ, σ, μ) -> f.lag_h(res, θ, σ, μ, p)
    end

    return OptimizationFunction{true}(f.f, adtype; grad = grad, hess = hess, hv = hv,
        cons = cons, cons_j = cons_j, cons_h = cons_h,
        cons_vjp = cons_vjp!, cons_jvp = cons_jvp!,
        hess_prototype = hess_sparsity,
        hess_colorvec = hess_colors,
        cons_jac_prototype = cons_jac_prototype,
        cons_jac_colorvec = cons_jac_colorvec,
        cons_hess_prototype = conshess_sparsity,
        cons_hess_colorvec = conshess_colors,
        lag_h,
        lag_hess_prototype = lag_hess_prototype,
        sys = f.sys,
        expr = f.expr,
        cons_expr = f.cons_expr)
end

function OptimizationBase.instantiate_function(
        f::OptimizationFunction{true}, cache::OptimizationBase.ReInitCache,
        adtype::ADTypes.AutoZygote, num_cons = 0)
    x = cache.u0
    p = cache.p

    return OptimizationBase.instantiate_function(f, x, adtype, p, num_cons)
end

function OptimizationBase.instantiate_function(
        f::OptimizationFunction{true}, x, adtype::ADTypes.AutoSparse{<:AutoZygote},
        p = SciMLBase.NullParameters(), num_cons = 0;
        fg = false, fgh = false, conshess = false,
        cons_vjp = false, cons_jvp = false)
    function _f(θ)
        return f.f(θ, p)[1]
    end

    adtype, soadtype = OptimizationBase.generate_sparse_adtype(adtype)

    if f.grad === nothing
        extras_grad = prepare_gradient(_f, adtype.dense_ad, x)
        function grad(res, θ)
            gradient!(_f, res, adtype.dense_ad, θ, extras_grad)
        end
    else
        grad = (G, θ) -> f.grad(G, θ, p)
    end

    if fg == true && f.fg !== nothing
        function fg!(res, θ)
            (y, _) = value_and_gradient!(_f, res, adtype.dense_ad, θ, extras_grad)
            return y
        end
    end

    hess_sparsity = f.hess_prototype
    hess_colors = f.hess_colorvec
    if f.hess === nothing
        extras_hess = prepare_hessian(_f, soadtype, x) #placeholder logic, can be made much better
        function hess(res, θ)
            hessian!(_f, res, soadtype, θ, extras_hess)
        end
        hess_sparsity = extras_hess.sparsity
        hess_colors = extras_hess.colors
    else
        hess = (H, θ) -> f.hess(H, θ, p)
    end

    if fgh == true && f.fgh !== nothing
        function fgh!(G, H, θ)
            (y, _, _) = value_derivative_and_second_derivative!(_f, G, H, θ, extras_hess)
            return y
        end
    end

    if f.hv === nothing
        extras_hvp = prepare_hvp(_f, soadtype.dense_ad, x, zeros(eltype(x), size(x)))
        hv = function (H, θ, v)
            hvp!(_f, H, soadtype.dense_ad, θ, v, extras_hvp)
        end
    else
        hv = f.hv
    end

    if f.cons === nothing
        cons = nothing
    else
        function cons(res, θ)
            f.cons(res, θ, p)
        end

        function cons_oop(x)
            _res = Zygote.Buffer(x, num_cons)
            f.cons(_res, x, p)
            return copy(_res)
        end

        function lagrangian(x, σ = one(eltype(x)), λ = ones(eltype(x), num_cons))
            return σ * _f(x) + dot(λ, cons_oop(x))
        end
    end

    cons_jac_prototype = f.cons_jac_prototype
    cons_jac_colorvec = f.cons_jac_colorvec
    if cons !== nothing && f.cons_j === nothing
        extras_jac = prepare_jacobian(cons_oop, adtype, x)
        function cons_j(J, θ)
            jacobian!(cons_oop, J, adtype, θ, extras_jac)
            if size(J, 1) == 1
                J = vec(J)
            end
        end
        cons_jac_prototype = extras_jac.sparsity
        cons_jac_colorvec = extras_jac.colors
    else
        cons_j = (J, θ) -> f.cons_j(J, θ, p)
    end

    if f.cons_vjp === nothing && cons_vjp == true
        extras_pullback = prepare_pullback(cons_oop, adtype, x)
        function cons_vjp!(J, θ, v)
            pullback!(cons_oop, J, adtype.dense_ad, θ, v, extras_pullback)
        end
    else
        cons_vjp! = nothing
    end

    if f.cons_jvp === nothing && cons_jvp == true
        extras_pushforward = prepare_pushforward(cons_oop, adtype, x)
        function cons_jvp!(J, θ, v)
            pushforward!(cons_oop, J, adtype.dense_ad, θ, v, extras_pushforward)
        end
    else
        cons_jvp! = nothing
    end

    conshess_sparsity = f.cons_hess_prototype
    conshess_colors = f.cons_hess_colorvec
    if cons !== nothing && f.cons_h === nothing && conshess == true
        fncs = [@closure (x) -> cons_oop(x)[i] for i in 1:num_cons]
        extras_cons_hess = Vector(undef, length(fncs))
        for ind in 1:num_cons
            extras_cons_hess[ind] = prepare_hessian(fncs[ind], soadtype, x)
        end
        conshess_sparsity = getfield.(extras_cons_hess, :sparsity)
        conshess_colors = getfield.(extras_cons_hess, :colors)
        function cons_h(H, θ)
            for i in 1:num_cons
                hessian!(fncs[i], H[i], soadtype, θ, extras_cons_hess[i])
            end
        end
    else
        cons_h = (res, θ) -> f.cons_h(res, θ, p)
    end

    lag_hess_prototype = f.lag_hess_prototype
    if cons !== nothing && f.lag_h === nothing
        lag_extras = prepare_hessian(lagrangian, soadtype, x)
        lag_hess_prototype = lag_extras.sparsity

        function lag_h(H::AbstractMatrix, θ, σ, λ)
            if σ == zero(eltype(θ))
                cons_h(H, θ)
                H *= λ
            else
                hessian!(x -> lagrangian(x, σ, λ), H, soadtype, θ, lag_extras)
            end
        end

        function lag_h(h, θ, σ, λ)
            H = eltype(θ).(lag_hess_prototype)
            hessian!((x) -> lagrangian(x, σ, λ), H, soadtype, θ, lag_extras)
            k = 0
            rows, cols, _ = findnz(H)
            for (i, j) in zip(rows, cols)
                if i <= j
                    k += 1
                    h[k] = H[i, j]
                end
            end
        end
    else
        lag_h = (res, θ, σ, μ) -> f.lag_h(res, θ, σ, μ, p)
    end
    return OptimizationFunction{true}(f.f, adtype; grad = grad, hess = hess, hv = hv,
        cons = cons, cons_j = cons_j, cons_h = cons_h,
        hess_prototype = hess_sparsity,
        hess_colorvec = hess_colors,
        cons_jac_prototype = cons_jac_prototype,
        cons_jac_colorvec = cons_jac_colorvec,
        cons_hess_prototype = conshess_sparsity,
        cons_hess_colorvec = conshess_colors,
        lag_h,
        lag_hess_prototype = lag_hess_prototype,
        sys = f.sys,
        expr = f.expr,
        cons_expr = f.cons_expr)
end

function OptimizationBase.instantiate_function(
        f::OptimizationFunction{true}, cache::OptimizationBase.ReInitCache,
        adtype::ADTypes.AutoSparse{<:AutoZygote}, num_cons = 0)
    x = cache.u0
    p = cache.p

    return OptimizationBase.instantiate_function(f, x, adtype, p, num_cons)
end

end
