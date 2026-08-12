/* dmabuf_probe: CUDA dma-buf export + mlx5 ibv_reg_dmabuf_mr feasibility.
 * Answers: (1) CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED on this GPU/driver,
 * (2) cuMemGetHandleForAddressRange(DMA_BUF_FD) works without static BAR1,
 * (3) ConnectX-4 Lx accepts ibv_reg_dmabuf_mr (the publicly-unanswered gate).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <cuda.h>
#include <infiniband/verbs.h>

#define CK(call) do { CUresult r = (call); if (r != CUDA_SUCCESS) { \
    const char *s = "?"; cuGetErrorString(r, &s); \
    printf("FAIL: %s -> %d (%s)\n", #call, r, s); exit(2); } } while (0)

int main(void)
{
    CK(cuInit(0));
    CUdevice dev; CK(cuDeviceGet(&dev, 0));
    char name[128] = {0}; cuDeviceGetName(name, sizeof(name), dev);

    int dmabuf_sup = -1;
    CK(cuDeviceGetAttribute(&dmabuf_sup, CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED, dev));
    printf("gpu=%s DMA_BUF_SUPPORTED=%d\n", name, dmabuf_sup);
    if (!dmabuf_sup) { printf("VERDICT: dma-buf unsupported on this GPU/driver\n"); return 1; }

    CUresult cuCtxCreate_v2(CUcontext *, unsigned int, CUdevice);
    CUcontext ctx; CK(cuCtxCreate_v2(&ctx, 0, dev));
    size_t sz = 64UL << 20;
    CUdeviceptr dptr; CK(cuMemAlloc(&dptr, sz));

    int fd = -1;
    CUresult r = cuMemGetHandleForAddressRange(&fd, dptr, sz,
                    CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD, 0);
    if (r != CUDA_SUCCESS) {
        const char *s = "?"; cuGetErrorString(r, &s);
        printf("FAIL: cuMemGetHandleForAddressRange -> %d (%s)\n", r, s);
        return 2;
    }
    printf("dmabuf export OK: fd=%d size=%zu\n", fd, sz);

    int num = 0;
    struct ibv_device **list = ibv_get_device_list(&num);
    struct ibv_device *want = NULL;
    for (int i = 0; i < num; i++)
        if (!strcmp(ibv_get_device_name(list[i]), "mlx5_0")) want = list[i];
    if (!want) { printf("FAIL: mlx5_0 not found (%d devices)\n", num); return 2; }

    struct ibv_context *ibctx = ibv_open_device(want);
    if (!ibctx) { printf("FAIL: ibv_open_device errno=%d\n", errno); return 2; }
    struct ibv_pd *pd = ibv_alloc_pd(ibctx);
    if (!pd) { printf("FAIL: ibv_alloc_pd errno=%d\n", errno); return 2; }

    struct ibv_mr *mr = ibv_reg_dmabuf_mr(pd, 0, sz, 0, fd,
        IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE);
    if (!mr) {
        printf("ibv_reg_dmabuf_mr FAILED errno=%d (%s)\n", errno, strerror(errno));
        printf("VERDICT: CX-4 Lx does NOT accept dmabuf MR of GPU memory\n");
        return 1;
    }
    printf("ibv_reg_dmabuf_mr OK: lkey=0x%x rkey=0x%x\n", mr->lkey, mr->rkey);
    printf("VERDICT: CX-4 Lx + A2000 dmabuf GPU-MR WORKS\n");
    ibv_dereg_mr(mr);
    ibv_dealloc_pd(pd);
    ibv_close_device(ibctx);
    close(fd);
    cuMemFree(dptr);
    return 0;
}
