#include <libavutil/frame.h>
#include "cuda.h"
#include "VideoProcessor.h"


__global__ void resizeNV12NearestKernel(unsigned char* inputY, unsigned char* inputUV, unsigned char* outputY, unsigned char* outputUV,
	int srcWidth, int srcHeight, int srcLinesizeY, int srcLinesizeUV, int dstWidth, int dstHeight, float xRatio, float yRatio) {

	unsigned int i = blockIdx.y * blockDim.y + threadIdx.y; //coordinate of pixel (y) in destination image
	unsigned int j = blockIdx.x * blockDim.x + threadIdx.x; //coordinate of pixel (x) in destination image

	if (i < dstHeight && j < dstWidth) {
		int y = (int)(yRatio * i); //it's coordinate of pixel in source image
		int x = (int)(xRatio * j); //it's coordinate of pixel in source image
		int index = y * srcLinesizeY + x; //index in source image
		outputY[i * dstWidth + j] = inputY[index];
		//we should take chroma for every 2 luma, also height of data[1] is twice less than data[0]
		//there are no difference between x_ratio for Y and UV also as for y_ratio because (src_height / 2) / (dst_height / 2) = src_height / dst_height
		if (j % 2 == 0 && i < dstHeight / 2) {
			index = y * srcLinesizeUV + x; //index in source image
			int indexU, indexV;
			if (index % 2 == 0) {
				indexU = index;
				indexV = index + 1;
			}
			else {
				indexU = index - 1;
				indexV = index;
			}
			outputUV[i * dstWidth + j] = inputUV[indexU];
			outputUV[i * dstWidth + j + 1] = inputUV[indexV];
		}
	}
}

__device__ int calculateBillinearInterpolation(unsigned char* data, int startIndex, int xDiff, int yDiff, int linesize, int weightX, int weightY) {
	// range is 0 to 255 thus bitwise AND with 0xff
	int A = data[startIndex] & 0xff;
	int B = data[startIndex + xDiff] & 0xff;
	int C = data[startIndex + linesize] & 0xff;
	int D = data[startIndex + linesize + yDiff] & 0xff;

	// value = A(1-w)(1-h) + B(w)(1-h) + C(h)(1-w) + Dwh
	int value = (int)(
		A * (1 - weightX) * (1 - weightY) +
		B * (weightX) * (1 - weightY) +
		C * (weightY) * (1 - weightX) +
		D * (weightX  *      weightY)
		);
	return value;
}

__global__ void resizeNV12BilinearKernel(unsigned char* inputY, unsigned char* inputUV, unsigned char* outputY, unsigned char* outputUV,
	int srcWidth, int srcHeight, int srcLinesizeY, int srcLinesizeUV, int dstWidth, int dstHeight, float xRatio, float yRatio) {

	unsigned int i = blockIdx.y * blockDim.y + threadIdx.y; //coordinate of pixel (y) in destination image
	unsigned int j = blockIdx.x * blockDim.x + threadIdx.x; //coordinate of pixel (x) in destination image

	if (i < dstHeight && j < dstWidth) {
		int y = (int)(yRatio * i); //it's coordinate of pixel in source image
		int x = (int)(xRatio * j); //it's coordinate of pixel in source image
		float xFloat = (xRatio * j) - x;
		float yFloat = (yRatio * i) - y;
		int index = y * srcLinesizeY + x; //index in source image
		outputY[i * dstWidth + j] = calculateBillinearInterpolation(inputY, index, 1, 1, srcLinesizeY, xFloat, yFloat);
		//we should take chroma for every 2 luma, also height of data[1] is twice less than data[0]
		//there are no difference between x_ratio for Y and UV also as for y_ratio because (src_height / 2) / (dst_height / 2) = src_height / dst_height
		if (j % 2 == 0 && i < dstHeight / 2) {
			index = y * srcLinesizeUV + x; //index in source image
			int indexU, indexV;
			if (index % 2 == 0) {
				indexU = index;
				indexV = index + 1;
			}
			else {
				indexU = index - 1;
				indexV = index;
			}
			outputUV[i * dstWidth + j] = calculateBillinearInterpolation(inputUV, indexU, 2, 2, srcLinesizeUV, xFloat, yFloat);
			outputUV[i * dstWidth + j + 1] = calculateBillinearInterpolation(inputUV, indexV, 2, 2, srcLinesizeUV, xFloat, yFloat);
		}
	}
}

int resizeKernel(AVFrame* src, AVFrame* dst, ResizeType resize, int maxThreadsPerBlock, cudaStream_t * stream) {
	unsigned char* outputY = nullptr;
	unsigned char* outputUV = nullptr;
	cudaError err = cudaMalloc(&outputY, dst->width * dst->height * sizeof(unsigned char)); //in resize we don't change color format
	err = cudaMalloc(&outputUV, dst->width * (dst->height / 2) * sizeof(unsigned char));
	//need to execute for width and height
	dim3 threadsPerBlock(64, maxThreadsPerBlock / 64);
	int blockX = std::ceil(dst->width / (float)threadsPerBlock.x);
	int blockY = std::ceil(dst->height / (float)threadsPerBlock.y);
	dim3 numBlocks(blockX, blockY);
	float xRatio = ((float)(src->width - 1)) / dst->width; //if not -1 we should examine 2x2 square with top-left corner in the last pixel of src, so it's impossible
	float yRatio = ((float)(src->height - 1)) / dst->height;
	if (resize == ResizeType::BILINEAR) {
		resizeNV12BilinearKernel << <numBlocks, threadsPerBlock, 0, *stream >> > (src->data[0], src->data[1], outputY, outputUV,
			src->width, src->height, src->linesize[0], src->linesize[1],
			dst->width, dst->height, xRatio, yRatio);
	}
	else if (resize == ResizeType::NEAREST) {
		resizeNV12NearestKernel << <numBlocks, threadsPerBlock, 0, *stream >> > (src->data[0], src->data[1], outputY, outputUV,
			src->width, src->height, src->linesize[0], src->linesize[1],
			dst->width, dst->height, xRatio, yRatio);
	}
	dst->data[0] = outputY;
	dst->data[1] = outputUV;
	return err;
}
