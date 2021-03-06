#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include "glm/glm.hpp"
#include "utilities.h"
#include "kernel.h"

#if SHARED == 1
    #define ACC(x,y,z) sharedMemAcc(x,y,z)
#else
    #define ACC(x,y,z) naiveAcc(x,y,z)
#endif

//GLOBALS
dim3 threadsPerBlock(blockSize);

int numObjects;
const float planetMass = 3e8;
const __device__ float starMass = 5e10;
const __device__ int integrateMode = (int)EULER;
const float scene_scale = 2e2; //size of the height map in simulation space

vec4 * dev_pos;
vec3 * dev_vel;

void checkCUDAError(const char *msg, int line = -1)
{
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err)
    {
        if( line >= 0 )
        {
            fprintf(stderr, "Line %d: ", line);
        }
        fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
        exit(EXIT_FAILURE); 
    }
} 

__host__ __device__
unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

//Function that generates static.
__host__ __device__ 
vec3 generateRandomNumberFromThread(float time, int index)
{
    thrust::default_random_engine rng(hash(index*time));
    thrust::uniform_real_distribution<float> u01(0,1);

    return vec3((float) u01(rng), (float) u01(rng), (float) u01(rng));
}

//Generate randomized starting positions for the planets in the XY plane
//Also initialized the masses
__global__
void generateRandomPosArray(int time, int N, vec4 * arr, float scale, float mass)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        vec3 rand = scale*(generateRandomNumberFromThread(time, index)-0.5f);
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = 0.0f;//rand.z;
        arr[index].w = mass;
    }
}

//Determine velocity from the distance from the center star. Not super physically accurate because 
//the mass ratio is too close, but it makes for an interesting looking scene
__global__
void generateCircularVelArray(int time, int N, vec3 * arr, vec4 * pos)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        vec3 R = vec3(pos[index].x, pos[index].y, pos[index].z);
        float r = glm::length(R) + EPSILON;
        float s = sqrt(G*starMass/r);
        vec3 D = glm::normalize(glm::cross(R/r,vec3(0,0,1)));
        arr[index].x = s*D.x;
        arr[index].y = s*D.y;
        arr[index].z = s*D.z;
    }
}

//Generate randomized starting velocities in the XY plane
__global__
void generateRandomVelArray(int time, int N, vec3 * arr, float scale)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        vec3 rand = scale*(generateRandomNumberFromThread(time, index) - 0.5f);
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = 0.0;//rand.z;
    }
}

//TODO: Determine force between two bodies
__device__
vec3 calculateAcceleration(vec4 us, vec4 them)
{
    //    G*m_us*m_them
    //F = -------------
    //         r^2
    //
    //    G*m_us*m_them   G*m_them
    //a = ------------- = --------
    //      m_us*r^2        r^2
    
	//float eps = 0.1f; // protect against division of small number
	float eps = 1e-6; // protect against division of small number
   	vec4 rvec4 = them-us;
	vec3 rvec = vec3(rvec4.x, rvec4.y, rvec4.z);
	//vec3 accDir = glm::normalize(rvec);
	float r = glm::length(rvec) + eps;
	vec3 a = ((float)G * them.w * rvec) / (r * r * r);
	return a;
}

//TODO: Core force calc kernel global memory
__device__ 
vec3 naiveAcc(int N, vec4 my_pos, vec4 * their_pos)
{    
	vec3 acc = calculateAcceleration(my_pos, vec4(0,0,0,starMass));

	for (int i = 0 ; i < N ; ++i)
	{
		acc += calculateAcceleration(my_pos, their_pos[i]);
	}

	return acc;
}


//TODO: Core force calc kernel shared memory
__device__ 
vec3 sharedMemAcc(int N, vec4 my_pos, vec4 * their_pos)
{
	// the exact size of the shared memory is determined during the kernel launch. See the third parameter!
	extern __shared__ vec4 sharedPositions[];

	vec3 acc = calculateAcceleration(my_pos, vec4(0,0,0,starMass));
	for (int i = 0, int tileNum = 0 ; i < N ; i = i + (int)blockSize, ++tileNum)
	{
		int id = tileNum * blockDim.x + threadIdx.x;
		if (id < N)
			sharedPositions[threadIdx.x] = their_pos[id];

		__syncthreads();

		// iterate through all the sharePositions set by all threads within this tile
		for (int j = 0 ; j < blockDim.x ; ++j)
		{
			// need to make sure that the current sharedPosition that we are trying to access 
			// falls within the total objects that we have.
			int index = tileNum * blockDim.x + j;
			if (index < N)
				acc += calculateAcceleration(my_pos, sharedPositions[j]);
		}

		__syncthreads();
	}

    return acc;
}

__device__
vec3 integrateAcceleration(vec3 vel, vec3 acc, float dt, int N, vec4 mypos, vec4 *positions)
{
	vec3 nextVel = vec3(0,0,0);

	if (integrateMode == (int)EULER)
	{
		nextVel = vel + acc * dt;
	}
	else if (integrateMode == (int)RK2)
	{
		float halfDt = 0.5f * dt;
		vec3 halfStepVel = vel + acc * halfDt;
		vec3 halfStepPos = vec3(mypos) + halfStepVel * halfDt;
		vec3 halfAcc = ACC(N, mypos, positions);

		nextVel = vel + halfAcc * dt;
	}
	else if (integrateMode == (int)RK4)
	{
		// TODO
	}
	else 
	{
		// error
	}

	return nextVel;
}

__device__
vec3 integrateVelocity(vec3 position, vec3 velocity, float dt)
{
	vec3 nextPosition = vec3(0,0,0);

	if (integrateMode == (int)EULER)
	{
		nextPosition = position + velocity * dt;
	}
	else if (integrateMode == (int)RK2)
	{
		float halfDt = 0.5f * dt;
		vec3 halfStepPos = position + velocity * halfDt;
		vec3 halfStepVel = (halfStepPos - position) / halfDt;
		nextPosition = position + halfStepVel * dt;
	}
	else if (integrateMode == (int)RK4)
	{
		// TODO
	}
	else
	{
		// error
	}

	return nextPosition;
}

//Simple Euler integration scheme
__global__
void updateVelocity(int N, float dt, vec4 * pos, vec3 * vel)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if( index < N )
    {
        vec4 my_pos = pos[index];
        vec3 acc = ACC(N, my_pos, pos);
		//vel[index] += acc * dt;
		vel[index] = integrateAcceleration(vel[index], acc, dt, N, my_pos, pos);
    }
}

__global__
void updatePosition(int N, float dt, vec4 *pos, vec3 *vel)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	if (index < N )
	{
		vec3 nextPosition = integrateVelocity(vec3(pos[index]), vel[index], dt);

		pos[index].x = nextPosition.x;
		pos[index].y = nextPosition.y;
		pos[index].z = nextPosition.z;

		//pos[index].x += vel[index].x * dt;
		//pos[index].y += vel[index].y * dt;
		//pos[index].z += vel[index].z * dt;
	}
}

//Update the vertex buffer object
//(The VBO is where OpenGL looks for the positions for the planets)
__global__
void sendToVBO(int N, vec4 * pos, float * vbo, int width, int height, float s_scale)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale_w = -2.0f / s_scale;
    float c_scale_h = -2.0f / s_scale;

    if(index<N)
    {
        vbo[4*index+0] = pos[index].x*c_scale_w;
        vbo[4*index+1] = pos[index].y*c_scale_h;
        vbo[4*index+2] = 0;
        vbo[4*index+3] = 1;
    }
}

//Update the texture pixel buffer object
//(This texture is where openGL pulls the data for the height map)
__global__
void sendToPBO(int N, vec4 * pos, float4 * pbo, int width, int height, float s_scale)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    int x = index % width;
    int y = index / width;
    float w2 = width / 2.0;
    float h2 = height / 2.0;

    float c_scale_w = width / s_scale;
    float c_scale_h = height / s_scale;

    if(x<width && y<height)
    {
		// figure out the acceleration of the texel with respect to the rest of the N-body
		// these texels have a "weight" of 1 for the purpose of the calculations
        vec3 acc = ACC(N, vec4((x-w2)/c_scale_w,(y-h2)/c_scale_h,0,1), pos);
        float mag = 1*sqrt(sqrt(acc.x*acc.x + acc.y*acc.y + acc.z*acc.z)); // multiplying this by 2 makes the black area around spikes larger
        
		// Each thread writes one pixel location in the texture (textel)
        pbo[index].w = (mag < 1.0f) ? mag : 1.0f; // setting this to 0 makes the plane solid color with no heights
    }
}


/*************************************
 * Wrappers for the __global__ calls *
 *************************************/

//Initialize memory, update some globals
void initCuda(int N)
{
    numObjects = N;
    dim3 fullBlocksPerGrid((int)ceil(float(N)/float(blockSize)));

    cudaMalloc((void**)&dev_pos, N*sizeof(vec4));
    checkCUDAErrorWithLine("Kernel failed!");
    cudaMalloc((void**)&dev_vel, N*sizeof(vec3));
    checkCUDAErrorWithLine("Kernel failed!");

    generateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects, dev_pos, scene_scale, planetMass);
    checkCUDAErrorWithLine("Kernel failed!");
    generateCircularVelArray<<<fullBlocksPerGrid, blockSize>>>(2, numObjects, dev_vel, dev_pos);
    checkCUDAErrorWithLine("Kernel failed!");
	cudaThreadSynchronize();
}

void cudaNBodyUpdateWrapper(float dt)
{
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects)/float(blockSize)));
    updateVelocity<<<fullBlocksPerGrid, blockSize, blockSize * sizeof(vec4)>>>(numObjects, dt, dev_pos, dev_vel);
	updatePosition<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel);
    checkCUDAErrorWithLine("Kernel failed!");
	cudaThreadSynchronize();
}

void cudaUpdateVBO(float * vbodptr, int width, int height)
{
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects)/float(blockSize)));
    sendToVBO<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, vbodptr, width, height, scene_scale);
    checkCUDAErrorWithLine("Kernel failed!");
	cudaThreadSynchronize();
}

void cudaUpdatePBO(float4 * pbodptr, int width, int height)
{
    dim3 fullBlocksPerGrid((int)ceil(float(width*height)/float(blockSize)));
    sendToPBO<<<fullBlocksPerGrid, blockSize, blockSize * sizeof(vec4)>>>(numObjects, dev_pos, pbodptr, width, height, scene_scale);
    checkCUDAErrorWithLine("Kernel failed!");
	cudaThreadSynchronize();
}

