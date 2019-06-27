# DINCAE: Data-Interpolating Convolutional Auto-Encoder
# Copyright (C) 2019 Alexander Barth
#
# This file is part of DINCAE.

# DINCAE is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.

# DINCAE is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with DINCAE. If not, see <http://www.gnu.org/licenses/>.


# """
# DINCAE (Data-Interpolating Convolutional Auto-Encoder) is a neural network to
# reconstruct missing data in satellite observations.

# For most application it is sufficient to call the function
# `DINCAE.reconstruct_gridded_nc` directly.

# The code is available at:
# [https://github.com/gher-ulg/DINCAE](https://github.com/gher-ulg/DINCAE)
# """

module DINCAE
using NCDatasets
using Dates
using Random
using Printf
using Statistics
using TensorFlow

import Base: length
import Base: size
import Base: getindex
import Random: shuffle!

struct RVec{T,TV} <: AbstractVector{T} where TV <: AbstractVector{T}
    data::TV
    perm::Vector{Int}
end

RVec(d::TV) where TV <: AbstractVector{T} where T = RVec{T,TV}(d,randperm(length(d)))
Base.length(rv::RVec) = length(rv.data);
Base.size(rv::RVec) = size(rv.data);

function Base.getindex(rv::RVec,i::Integer)
    return rv.data[rv.perm[i]]
end

function Random.shuffle!(rv::RVec)
    randperm!(rv.perm)
    return rv
end



"""
Load the variable `varname` from the NetCDF file `fname`. The variable `lon` is
the longitude in degrees east, `lat` is the latitude in degrees North, `time` is
a numpy datetime vector, `data_full` is a 3-d array with the data, `missingmask`
is a boolean mask where true means the data is missing and `mask` is a boolean mask
where true means the data location is valid, e.g. sea points for sea surface temperature.

At the bare-minimum a NetCDF file should have the following variables and
attributes:


    netcdf file.nc {
    dimensions:
            time = UNLIMITED ; // (5266 currently)
            lat = 112 ;
            lon = 112 ;
    variables:
            double lon(lon) ;
            double lat(lat) ;
            double time(time) ;
                    time:units = "days since 1900-01-01 00:00:00" ;
            int mask(lat, lon) ;
            float SST(time, lat, lon) ;
                    SST:_FillValue = -9999.f ;
    }

"""
function load_gridded_nc(fname,varname)
    ds = Dataset(fname);
    lon = nomissing(ds["lon"][:])
    lat = nomissing(ds["lat"][:])
    #time = nomissing(ds["time"][:])
    #data = nomissing(ds[varname][:,:,:],NaN)

    time = nomissing(ds["time"][1:10])
    data = nomissing(ds[varname][:,:,1:10],NaN)

    mask = nomissing(ds["mask"][:,:]) .== 1;

    close(ds)
    missingmask = isnan.(data)

    return lon,lat,time,data,missingmask,mask
end


"""
Return a generator for training (`train = true`) or testing (`train = false`)
the neural network. `obs_err_std` is the error standard deviation of the
observations. The variable `lon` is the longitude in degrees east, `lat` is the
latitude in degrees North, `time` is a numpy datetime vector, `data_full` is a
3-d array with the data and `missingmask` is a boolean mask where true means the data is
missing. `jitter_std` is the standard deviation of the noise to be added to the
data during training.

The output of this function is `datagen`, `ntime` and `meandata`. `datagen` is a
generator function returning a single image (relative to the mean `meandata`),
`ntime` the number of time instances for training or testing and `meandata` is
the temporal mean of the data.
"""
function data_generator(lon,lat,time,data_full,missingmask;
                   train = true,
                   obs_err_std = 1.,
                   jitter_std = 0.05)
    ntime = size(data_full,3)

    meandata = mean(data_full,dims = 3)

    dayofyear = Dates.dayofyear.(time)
    dayofyear_cos = cos.(dayofyear/365.25)
    dayofyear_sin = sin.(dayofyear/365.25)

    data = data_full .- meandata

    sz = size(data)

    x = zeros(Float32,(sz[1],sz[2],sz[3],6))

    x[:,:,:,2] = (1 .- isfinite.(data)) / (obs_err_std^2)  # error variance
    x[:,:,:,1] = replace(data,NaN => 0) / (obs_err_std^2)

    # scale between -1 and 1
    lon_scaled = 2 * (lon .- minimum(lon)) / (maximum(lon) - minimum(lon)) .- 1
    lat_scaled = 2 * (lat .- minimum(lat)) / (maximum(lat) - minimum(lat)) .- 1

    x[:,:,:,3] .= reshape(lon_scaled,(length(lon),1,1))
    x[:,:,:,4] .= reshape(lat_scaled,(1,length(lat),1))
    x[:,:,:,5] .= reshape(dayofyear_cos,(1,1,length(dayofyear)))
    x[:,:,:,6] .= reshape(dayofyear_sin,(1,1,length(dayofyear)))

    # generator for data
    datagen = Channel() do channel
        for i in 1:sz[3]
            xin = zeros(Float32,(sz[1],sz[2],6+2*2))
            xin[:,:,1:6]  = x[:,:,i,:]
            xin[:,:,7:8]  = x[:,:,max(1,i-1),1:2] # previous
            xin[:,:,9:10] = x[:,:,min(sz[3],i+1),1:2] # next


            # add missing data during training randomly
            if train
                imask = rand(1:size(missingmask,3))
                selmask = @view missingmask[:,:,imask]

                (@view xin[:,:,1])[selmask] = 0
                (@view xin[:,:,2])[selmask] = 0

                # add jitter
                xin[:,:,1] = xin[:,:,1] + jitter_std * randn(sz[1],sz[2])
                xin[:,:,7] = xin[:,:,8] + jitter_std * randn(sz[1],sz[2])
                xin[:,:,9] = xin[:,:,9] + jitter_std * randn(sz[1],sz[2])
            end

            put!(channel,(xin,x[:,:,i,1:2]))
        end
    end

    return datagen,size(data,3),meandata
end




mutable struct NCData{T} <: AbstractVector{Tuple{Array{T,3},Array{T,3}}}
    lon::Vector{T}
    lat::Vector{T}
    time::Vector{DateTime}
    data_full::Array{T,3}
    missingmask::BitArray{3}
    meandata::Array{T,2}
    x::Array{T,4}
    train::Bool
    obs_err_std::T
    jitter_std::T
end


Base.length(dd::NCData) = length(dd.time)
Base.size(dd::NCData) = (length(dd.time),);

"""
Return a generator for training (`train = true`) or testing (`train = false`)
the neural network. `obs_err_std` is the error standard deviation of the
observations. The variable `lon` is the longitude in degrees east, `lat` is the
latitude in degrees North, `time` is a numpy datetime vector, `data_full` is a
3-d array with the data and `missingmask` is a boolean mask where true means the data is
missing. `jitter_std` is the standard deviation of the noise to be added to the
data during training.

The output of this function is `datagen`, `ntime` and `meandata`. `datagen` is a
generator function returning a single image (relative to the mean `meandata`),
`ntime` the number of time instances for training or testing and `meandata` is
the temporal mean of the data.
"""
function NCData(lon,lat,time,data_full,missingmask;
                train = true,
                obs_err_std = 1.,
                jitter_std = 0.05)
    meandata = mean(data_full,dims = 3)

    ntime = size(data_full,3)


    dayofyear = Dates.dayofyear.(time)
    dayofyear_cos = cos.(dayofyear/365.25)
    dayofyear_sin = sin.(dayofyear/365.25)

    data = data_full .- meandata

    sz = size(data)

    x = zeros(Float32,(sz[1],sz[2],sz[3],6))

    x[:,:,:,2] = (1 .- isfinite.(data)) / (obs_err_std^2)  # error variance
    x[:,:,:,1] = replace(data,NaN => 0) / (obs_err_std^2)

    # scale between -1 and 1
    lon_scaled = 2 * (lon .- minimum(lon)) / (maximum(lon) - minimum(lon)) .- 1
    lat_scaled = 2 * (lat .- minimum(lat)) / (maximum(lat) - minimum(lat)) .- 1

    x[:,:,:,3] .= reshape(lon_scaled,(length(lon),1,1))
    x[:,:,:,4] .= reshape(lat_scaled,(1,length(lat),1))
    x[:,:,:,5] .= reshape(dayofyear_cos,(1,1,length(dayofyear)))
    x[:,:,:,6] .= reshape(dayofyear_sin,(1,1,length(dayofyear)))

    NCData(Float32.(lon),Float32.(lat),time,data_full,missingmask,meandata[:,:,1],x,
           train,
           Float32(obs_err_std),
           Float32(jitter_std))
end

function Base.getindex(dd::NCData,i::Integer)
    sz = size(dd.data_full)
    xin = zeros(Float32,(sz[1],sz[2],6+2*2))
    xin[:,:,1:6]  = dd.x[:,:,i,:]
    xin[:,:,7:8]  = dd.x[:,:,max(1,i-1),1:2] # previous
    xin[:,:,9:10] = dd.x[:,:,min(sz[3],i+1),1:2] # next

    # add missing data during training randomly
    if dd.train
        imask = rand(1:size(dd.missingmask,3))
        selmask = @view dd.missingmask[:,:,imask]

        (@view xin[:,:,1])[selmask] .= 0
        (@view xin[:,:,2])[selmask] .= 0

        # add jitter
        xin[:,:,1] = xin[:,:,1] + dd.jitter_std * randn(sz[1],sz[2])
        xin[:,:,7] = xin[:,:,8] + dd.jitter_std * randn(sz[1],sz[2])
        xin[:,:,9] = xin[:,:,9] + dd.jitter_std * randn(sz[1],sz[2])
    end

    return (xin,dd.x[:,:,i,1:2])
end

#=
function savesample(fname,batch_m_rec,batch_σ2_rec,meandata,lon,lat,e,ii,offset)
    fill_value = -9999.
    recdata = batch_m_rec # + meandata;
    batch_sigma_rec = sqrt.(batch_σ2_rec)

    if ii == 0
        # create file
        ds = Dataset(fname, "w")

        # dimensions
        defDim(ds,"time") = Inf
        defDim(ds,"lon", length(lon))
        defDim(ds,"lat", length(lat))

        # variables
        nc_lon = defVar(ds,"lon", Float32, ("lon",))
        nc_lat = defVar(ds,"lat", Float32, ("lat",))
        nc_meandata = defVar(
            ds,
            "meandata", Float32, ("lat","lon"),
            fill_value=fill_value)

        nc_batch_m_rec = defVar(
            ds,
            "batch_m_rec", Float32, ("time", "lat", "lon"),
            fill_value=fill_value)

        nc_batch_sigma_rec = defVar(
            ds,
            "batch_sigma_rec", Float32, ("time", "lat", "lon",),
            fill_value=fill_value)

        # data
        nc_lon[:] = lon
        nc_lat[:] = lat
        nc_meandata[:,:] = meandata
    else
        # append to file
        ds = Dataset(fname, "a")
        nc_batch_m_rec = ds.variables["batch_m_rec"]
        nc_batch_sigma_rec = ds.variables["batch_sigma_rec"]
    end

    for n in 1:size(batch_m_rec,3)
        # add mask
        nc_batch_m_rec[:,:,n+offset] = batch_m_rec[:,:,n]
        nc_batch_sigma_rec[:,:,n+offset] = batch_sigma_rec[:,:,n]
    end

    close(ds)
end
=#



# save inversion
function sinv(x; minx = 1e-3)
    return 1 / maximum.(x,minx)
end

"""
Train a neural network to reconstruct missing data using the training data set
and periodically run the neural network on the test dataset.

## Parameters

 * `lon`: longitude in degrees East
 * `lat`: latitude in degrees North
 * `mask`:  boolean mask where true means the data location is valid,
e.g. sea points for sea surface temperature.
 * `meandata`: the temporal mean of the data.
 * `train_datagen`: generator function returning a single image for training
 * `train_len`: number of training images
 * `test_datagen`: generator function returning a single image for testing
 * `test_len`: number of testing images
 * `outdir`: output directory

## Optional input arguments

 * `resize_method`: one of the resize methods defined in [TensorFlow](https://www.tensorflow.org/api_docs/python/tf/image/resize_images)
 * `epochs`: number of epochs for training the neural network
 * `batch_size`: size of a mini-batch
 * `save_each`: reconstruct the missing data every `save_each` epoch
 * `save_model_each`: save a checkpoint of the neural network every
      `save_model_each` epoch
 * `skipconnections`: list of indices of convolutional layers with
     skip-connections
 * `dropout_rate_train`: probability for drop-out during training
 * `tensorboard`: activate tensorboard diagnostics
 * `truth_uncertain`: how certain you are about the perceived truth?
 * `shuffle_buffer_size`: number of images for the shuffle buffer
 * `nvar`: number of input variables
 * `enc_ksize_internal`: kernel sizes for the internal convolutional layers
      (after the input convolutional layer)
 * `clip_grad`: clip gradient to a maximum L2-norm.
 * `regularization_L2_beta`: scalar to enforce L2 regularization on the weight
"""
function reconstruct(lon,lat,mask,meandata,
                train_datagen,train_len,
                test_datagen,test_len,
                outdir,
                resize_method = tf.image.ResizeMethod.NEAREST_NEIGHBOR,
                epochs = 1000,
                batch_size = 30,
                save_each = 10,
                save_model_each = 500,
                skipconnections = [1,2,3,4],
                dropout_rate_train = 0.3,
                tensorboard = false,
                truth_uncertain = false,
                shuffle_buffer_size = 3*15,
                nvar = 10,
                enc_ksize_internal = [16,24,36,54],
                clip_grad = 5.0,
                regularization_L2_beta = 0
)

    enc_ksize = [nvar]
    append!(enc_ksize,enc_ksize_internal)

    if !isdir(outdir)
        mkpath(outdir)
    end

    jmax,imax = size(mask)

    sess = TensorFlow.session()

    # # Repeat the input indefinitely.
    # # training dataset iterator
    # train_dataset = tf.data.Dataset.from_generator(
    #     train_datagen, (tf.float32,tf.float32),
    #     (tf.TensorShape([jmax,imax,nvar]),tf.TensorShape([jmax,imax,2]))).repeat().shuffle(shuffle_buffer_size).batch(batch_size)
    # train_iterator = train_dataset.make_one_shot_iterator()
    # train_iterator_handle = sess.run(train_iterator.string_handle())

    # # test dataset without added clouds
    # # must be reinitializable
    # test_dataset = tf.data.Dataset.from_generator(
    #     test_datagen, (tf.float32,tf.float32),
    #     (tf.TensorShape([jmax,imax,nvar]),tf.TensorShape([jmax,imax,2]))).batch(batch_size)

    # test_iterator = tf.data.Iterator.from_structure(test_dataset.output_types,
    #                                                 test_dataset.output_shapes)
    # test_iterator_init_op = test_iterator.make_initializer(test_dataset)

    # test_iterator_handle = sess.run(test_iterator.string_handle())

    # handle = tf.placeholder(tf.string, shape=[], name = "handle_name_iterator")
    # iterator = tf.data.Iterator.from_string_handle(
    #         handle, train_iterator.output_types, output_shapes = train_iterator.output_shapes)


    # inputs_,xtrue = iterator.get_next()



    # # encoder
    # enc_nlayers = length(enc_ksize)
    # enc_conv = [None] * enc_nlayers
    # enc_avgpool = [None] * enc_nlayers

    # enc_avgpool[0] = inputs_

    # for l in range(1,enc_nlayers):
    #     enc_conv[l] = tf.layers.conv2d(enc_avgpool[l-1],
    #                                    enc_ksize[l],
    #                                    (3,3),
    #                                    padding='same',
    #                                    activation=tf.nn.leaky_relu)
    #     print("encoder: output size of convolutional layer: ",l,enc_conv[l].shape)

    #     enc_avgpool[l] = tf.layers.average_pooling2d(enc_conv[l],
    #                                                  (2,2),
    #                                                  (2,2),
    #                                                  padding='same')

    #     print("encoder: output size of pooling layer: ",l,enc_avgpool[l].shape)

    #     enc_last = enc_avgpool[-1]

    # # Dense Layer
    # ndensein = enc_last.shape[1:].num_elements()

    # avgpool_flat = tf.reshape(enc_last, [-1, ndensein])
    # dense_units = [ndensein//5]

    # # default is no drop-out
    # dropout_rate = tf.placeholder_with_default(0.0, shape=())

    # dense = [None] * 5
    # dense[0] = avgpool_flat
    # dense[1] = tf.layers.dense(inputs=dense[0],
    #                            units=dense_units[0],
    #                            activation=tf.nn.relu)
    # dense[2] = tf.layers.dropout(inputs=dense[1], rate=dropout_rate)
    # dense[3] = tf.layers.dense(inputs=dense[2],
    #                            units=ndensein,
    #                            activation=tf.nn.relu)
    # dense[4] = tf.layers.dropout(inputs=dense[3], rate=dropout_rate)


    # dense_2d = tf.reshape(dense[-1], tf.shape(enc_last))

    # ### Decoder
    # dec_conv = [None] * enc_nlayers
    # dec_upsample = [None] * enc_nlayers

    # dec_conv[0] = dense_2d

    # for l in range(1,enc_nlayers):
    #     l2 = enc_nlayers-l
    #     dec_upsample[l] = tf.image.resize_images(
    #         dec_conv[l-1],
    #         enc_conv[l2].shape[1:3],
    #         method=resize_method)
    #     print("decoder: output size of upsample layer: ",l,dec_upsample[l].shape)

    #     # short-cut
    #     if l in skipconnections:
    #         print("skip connection at ",l)
    #         dec_upsample[l] = tf.concat([dec_upsample[l],enc_avgpool[l2-1]],3)
    #         print("decoder: output size of concatenation: ",l,dec_upsample[l].shape)

    #     dec_conv[l] = tf.layers.conv2d(
    #         dec_upsample[l],
    #         enc_ksize[l2-1],
    #         (3,3),
    #         padding='same',
    #         activation=tf.nn.leaky_relu)

    #     print("decoder: output size of convolutional layer: ",l,dec_conv[l].shape)

    # # last layer of decoder
    # xrec = dec_conv[-1]

    # loginvσ2_rec = xrec[:,:,:,1]
    # invσ2_rec = tf.exp(tf.minimum(loginvσ2_rec,10))
    # σ2_rec = sinv(invσ2_rec)
    # m_rec = xrec[:,:,:,0] * σ2_rec


    # σ2_true = sinv(xtrue[:,:,:,1])
    # m_true = xtrue[:,:,:,0] * σ2_true
    # σ2_in = sinv(inputs_[:,:,:,1])
    # m_in = inputs_[:,:,:,0] * σ2_in


    # difference = m_rec - m_true

    # mask_issea = tf.placeholder(
    #     tf.float32,
    #     shape = (mask.shape[0], mask.shape[1]),
    #     name = "mask_issea")

    # # 1 if measurement
    # # 0 if no measurement (cloud or land for SST)
    # mask_noncloud = tf.cast(tf.math.logical_not(tf.equal(xtrue[:,:,:,1], 0)),
    #                         xtrue.dtype)

    # n_noncloud = tf.reduce_sum(mask_noncloud)

    # if truth_uncertain:
    #     # KL divergence between two univariate Gaussians p and q
    #     # p ~ N(σ2_1,\mu_1)
    #     # q ~ N(σ2_2,\mu_2)
    #     #
    #     # 2 KL(p,q) = log(σ2_2/σ2_1) + (σ2_1 + (\mu_1 - \mu_2)^2)/(σ2_2) - 1
    #     # 2 KL(p,q) = log(σ2_2) - log(σ2_1) + (σ2_1 + (\mu_1 - \mu_2)^2)/(σ2_2) - 1
    #     # 2 KL(p_true,q_rec) = log(σ2_rec/σ2_true) + (σ2_true + (\mu_rec - \mu_true)^2)/(σ2_rec) - 1

    #     cost = (tf.reduce_sum(tf.multiply(
    #         tf.log(σ2_rec/σ2_true) + (σ2_true + difference**2) / σ2_rec,mask_noncloud))) / n_noncloud
    # else:
    #     cost = (tf.reduce_sum(tf.multiply(tf.log(σ2_rec),mask_noncloud)) +
    #         tf.reduce_sum(tf.multiply(difference**2 / σ2_rec,mask_noncloud))) / n_noncloud


    # # L2 regularization of weights
    # if regularization_L2_beta != 0:
    #     trainable_variables   = tf.trainable_variables()
    #     lossL2 = tf.add_n([ tf.nn.l2_loss(v) for v in trainable_variables
    #                         if 'bias' not in v.name ]) * regularization_L2_beta
    #     cost = cost + lossL2

    # RMS = tf.sqrt(tf.reduce_sum(tf.multiply(difference**2,mask_noncloud))
    #               / n_noncloud)

    # # to debug
    # # cost = RMS

    # if tensorboard:
    #     with tf.name_scope('Validation'):
    #         tf.summary.scalar('RMS', RMS)
    #         tf.summary.scalar('cost', cost)
    #         tf.summary.image("m_rec",tf.expand_dims(
    #             tf.reverse(tf.multiply(m_rec,mask_issea),[1]),-1))
    #         tf.summary.image("m_true",tf.expand_dims(
    #             tf.reverse(tf.multiply(m_true,mask_issea),[1]),-1))
    #         tf.summary.image("sigma2_rec",tf.expand_dims(
    #             tf.reverse(tf.multiply(σ2_rec,mask_issea),[1]),-1))

    # # parameters for Adam optimizer (default values)
    # learning_rate = 1e-3
    # beta1 = 0.9
    # beta2 = 0.999
    # epsilon = 1e-08

    # optimizer = tf.train.AdamOptimizer(learning_rate,beta1,beta2,epsilon)
    # gradients, variables = zip(*optimizer.compute_gradients(cost))
    # gradients, _ = tf.clip_by_global_norm(gradients, clip_grad)
    # opt = optimizer.apply_gradients(zip(gradients, variables))

    # dt_start = datetime.now()
    # print(dt_start)

    # if tensorboard:
    #     merged = tf.summary.merge_all()
    #     train_writer = tf.summary.FileWriter(outdir + '/train',
    #                                       sess.graph)
    #     test_writer = tf.summary.FileWriter(outdir + '/test')
    # else:
    #     # unused
    #     merged = tf.constant(0.0, shape=[1], dtype="float32")

    # index = 0

    # sess.run(tf.global_variables_initializer())

    # saver = tf.train.Saver()

    # # loop over epochs
    # for e in range(epochs):

    #     # loop over training datasets
    #     for ii in range(ceil(train_len / batch_size)):

    #         # run a single step of the optimizer
    #         summary, batch_cost, batch_RMS, bs, _ = sess.run(
    #             [merged, cost, RMS, mask_noncloud, opt],feed_dict={
    #                 handle: train_iterator_handle,
    #                 mask_issea: mask,
    #                 dropout_rate: dropout_rate_train})

    #         if tensorboard:
    #             train_writer.add_summary(summary, index)

    #         index += 1

    #         if ii % 20 == 0:
    #             print("Epoch: {}/{}...".format(e+1, epochs),
    #                   "Training loss: {:.4f}".format(batch_cost),
    #                   "RMS: {:.4f}".format(batch_RMS))

    #     if e % save_each == 0:
    #         print("Save output",e)

    #         timestr = datetime.now().strftime("%Y-%m-%dT%H%M%S")
    #         fname = os.path.join(outdir,"data-{}.nc".format(timestr))

    #         # reset test iterator, so that we start from the beginning
    #         sess.run(test_iterator_init_op)

    #         for ii in range(ceil(test_len / batch_size)):
    #             summary, batch_cost,batch_RMS,batch_m_rec,batch_σ2_rec = sess.run(
    #                 [merged, cost,RMS,m_rec,σ2_rec],
    #                 feed_dict = { handle: test_iterator_handle,
    #                               mask_issea: mask })

    #             # time instances already written
    #             offset = ii*batch_size
    #             savesample(fname,batch_m_rec,batch_σ2_rec,meandata,lon,lat,e,ii,
    #                        offset)

    #     if e % save_model_each == 0:
    #         save_path = saver.save(sess, os.path.join(
    #             outdir,"model-{:03d}.ckpt".format(e+1)))

    # dt_end = datetime.now()
    # print(dt_end)
    # print(dt_end - dt_start)
end

end
