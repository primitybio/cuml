/*
 * Copyright (c) 2018-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <common/cudart_utils.h>
#include <raft/linalg/cublas_wrappers.h>
#include <cuda_utils.cuh>
#include <linalg/add.cuh>
#include <linalg/binary_op.cuh>
#include <linalg/map_then_reduce.cuh>
#include <linalg/matrix_vector_op.cuh>
#include <stats/mean.cuh>
#include <vector>
#include "simple_mat.cuh"

namespace ML {
namespace GLM {

template <typename T>
inline void linearFwd(const raft::handle_t &handle, SimpleMat<T> &Z,
                      const SimpleMat<T> &X, const SimpleMat<T> &W,
                      cudaStream_t stream) {
  // Forward pass:  compute Z <- W * X.T + bias
  const bool has_bias = X.n != W.n;
  const int D = X.n;
  if (has_bias) {
    SimpleVec<T> bias;
    SimpleMat<T> weights;
    col_ref(W, bias, D);
    col_slice(W, weights, 0, D);
    // We implement Z <- W * X^T + b by
    // - Z <- b (broadcast): TODO reads Z unnecessarily atm
    // - Z <- W * X^T + Z    : TODO can be fused in CUTLASS?
    auto set_bias = [] __device__(const T z, const T b) { return b; };
    raft::linalg::matrixVectorOp(Z.data, Z.data, bias.data, Z.n, Z.m, false,
                                 false, set_bias, stream);

    Z.assign_gemm(handle, 1, weights, false, X, true, 1, stream);
  } else {
    Z.assign_gemm(handle, 1, W, false, X, true, 0, stream);
  }
}

template <typename T>
inline void linearBwd(const raft::handle_t &handle, SimpleMat<T> &G,
                      const SimpleMat<T> &X, const SimpleMat<T> &dZ,
                      bool setZero, cudaStream_t stream) {
  // Backward pass:
  // - compute G <- dZ * X.T
  // - for bias: Gb = mean(dZ, 1)

  const bool has_bias = X.n != G.n;
  const int D = X.n;
  const T beta = setZero ? T(0) : T(1);
  if (has_bias) {
    SimpleVec<T> Gbias;
    SimpleMat<T> Gweights;
    col_ref(G, Gbias, D);
    col_slice(G, Gweights, 0, D);

    // TODO can this be fused somehow?
    Gweights.assign_gemm(handle, 1.0 / X.m, dZ, false, X, false, beta, stream);
    raft::stats::mean(Gbias.data, dZ.data, dZ.m, dZ.n, false, true, stream);
  } else {
    G.assign_gemm(handle, 1.0 / X.m, dZ, false, X, false, beta, stream);
  }
}

struct GLMDims {
  bool fit_intercept;
  int C, D, dims, n_param;
  GLMDims(int C, int D, bool fit_intercept)
    : C(C), D(D), fit_intercept(fit_intercept) {
    dims = D + fit_intercept;
    n_param = dims * C;
  }
};

template <typename T, class Loss>
struct GLMBase : GLMDims {
  typedef SimpleMat<T> Mat;
  typedef SimpleVec<T> Vec;

  const raft::handle_t &handle;

  GLMBase(const raft::handle_t &handle, int D, int C, bool fit_intercept)
    : GLMDims(C, D, fit_intercept), handle(handle) {}

  /*
   * Computes the following:
   * 1. Z <- dL/DZ
   * 2. loss_val <- sum loss(Z)
   *
   * Default: elementwise application of loss and its derivative
   */
  inline void getLossAndDZ(T *loss_val, SimpleMat<T> &Z, const SimpleVec<T> &y,
                           cudaStream_t stream) {
    // Base impl assumes simple case C = 1
    Loss *loss = static_cast<Loss *>(this);
    T invN = 1.0 / y.len;

    auto f_l = [=] __device__(const T y, const T z) {
      return loss->lz(y, z) * invN;
    };

    // TODO would be nice to have a kernel that fuses these two steps
    // This would be easy, if mapThenSumReduce allowed outputing the result of
    // map (supporting inplace)
    raft::linalg::mapThenSumReduce(loss_val, y.len, f_l, stream, y.data,
                                   Z.data);

    auto f_dl = [=] __device__(const T y, const T z) {
      return loss->dlz(y, z);
    };
    raft::linalg::binaryOp(Z.data, y.data, Z.data, y.len, f_dl, stream);
  }

  inline void loss_grad(T *loss_val, Mat &G, const Mat &W,
                        const SimpleMat<T> &Xb, const Vec &yb, Mat &Zb,
                        cudaStream_t stream, bool initGradZero = true) {
    Loss *loss = static_cast<Loss *>(this);  // static polymorphism

    linearFwd(handle, Zb, Xb, W, stream);          // linear part: forward pass
    loss->getLossAndDZ(loss_val, Zb, yb, stream);  // loss specific part
    linearBwd(handle, G, Xb, Zb, initGradZero,
              stream);  // linear part: backward pass
  }
};

template <typename T, class GLMObjective>
struct GLMWithData : GLMDims {
  typedef SimpleMat<T> Mat;
  typedef SimpleVec<T> Vec;

  SimpleMat<T> X;
  Mat Z;
  Vec y;
  GLMObjective *objective;
  Vec lossVal;

  GLMWithData(GLMObjective *obj, T *Xptr, T *yptr, T *Zptr, int N,
              STORAGE_ORDER ordX)
    : objective(obj),
      X(Xptr, N, obj->D, ordX),
      y(yptr, N),
      Z(Zptr, obj->C, N),
      GLMDims(obj->C, obj->D, obj->fit_intercept) {}

  // interface exposed to typical non-linear optimizers
  inline T operator()(const Vec &wFlat, Vec &gradFlat, T *dev_scalar,
                      cudaStream_t stream) {
    Mat W(wFlat.data, C, dims);
    Mat G(gradFlat.data, C, dims);
    objective->loss_grad(dev_scalar, G, W, X, y, Z, stream);
    lossVal.reset(dev_scalar, 1);
    T loss_host;
    raft::update_host(&loss_host, lossVal.data, 1, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    return loss_host;
  }
};

};  // namespace GLM
};  // namespace ML
