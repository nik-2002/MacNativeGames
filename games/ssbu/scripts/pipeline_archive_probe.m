/* Probe for the pipeline archive (third_party/d2r_gfx/gfx/nvn/totk_pipeline_archive.h) on this Mac's GPU, without the game.
   Run twice on the same folder:
     write  a render and a compute pipeline are compiled (no file yet: a miss), handed to par_add, and must be on disk as
            their own .metalarchive files once the idle writer ran; Metal's build folders must not be left behind
     read   a new process: both pipelines must come from their files with MTLPipelineOptionFailOnBinaryArchiveMiss (Metal
            refuses to compile), so a pass means the archive really held them
   usage: pipeline-archive-probe <folder> write|read */
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#define MLOG(...) do { fprintf(stderr, "[archive-probe] " __VA_ARGS__); fputc('\n', stderr); } while (0)
static NSString *g_dir;
NSString *totk_rt_dir(void) { return g_dir; }
#include "../third_party/d2r_gfx/gfx/nvn/totk_pipeline_archive.h"
static int par_game_idle(void) { return 1; }
static int fails;
static void need(int c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) fails++; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 || (strcmp(argv[2], "write") && strcmp(argv[2], "read"))) { fprintf(stderr, "usage: pipeline-archive-probe <folder> write|read\n"); return 2; }
        g_dir = @(argv[1]); int write = !strcmp(argv[2], "write");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { fprintf(stderr, "no Metal device\n"); return 2; }
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint i [[vertex_id]]) { return float4(float(i & 1), float(i >> 1), 0, 1); }\n"
            "fragment half4 f() { return half4(0.25h, 0.5h, 0.75h, 1); }\n"
            "kernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i * 3; }\n";
        NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
        if (!lib) { fprintf(stderr, "library: %s\n", e.localizedDescription.UTF8String); return 2; }
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"v"]; rd.fragmentFunction = [lib newFunctionWithName:@"f"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new]; cd.computeFunction = [lib newFunctionWithName:@"k"];
        NSString *rkey = par_hash("probe-render", 12), *ckey = [@"c" stringByAppendingString:par_hash("probe-compute", 13)];
        id<MTLBinaryArchive> ra = par_archive_for(dev, rkey), ca = par_archive_for(dev, ckey);
        need(g_par_on, "archive on (TOTK_PIPELINE_ARCHIVE unset)");
        if (write) {
            need(!ra && !ca, "no files yet: both pipelines miss");
            NSSet *before = par_ga_list(0);
            id rp = [dev newRenderPipelineStateWithDescriptor:rd error:&e], cp = [dev newComputePipelineStateWithDescriptor:cd options:0 reflection:nil error:&e];
            need(rp && cp, "both pipelines compile");
            par_add(dev, rkey, rd); par_add(dev, ckey, cd);
            for (int i = 0; i < 100 && atomic_load(&g_par_written) < 2; i++) usleep(50000);   // the writer starts after 1 s
            need(atomic_load(&g_par_written) == 2 && !atomic_load(&g_par_write_failed), "both written by the idle writer");
            need([NSFileManager.defaultManager fileExistsAtPath:par_file(rkey)] && [NSFileManager.defaultManager fileExistsAtPath:par_file(ckey)], "one .metalarchive file each");
            NSMutableSet *left = [par_ga_list(0) mutableCopy]; [left minusSet:before];
            need(left.count == 0, "Metal's gpuarchiver build folders removed");
        } else {
            need(ra && ca, "both files open in a new process");
            rd.binaryArchives = @[ra]; cd.binaryArchives = @[ca];
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            id rp = [dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
            id cp = [dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
            double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
            need(rp != nil, "render pipeline from its file alone (FailOnBinaryArchiveMiss)");
            need(cp != nil, "compute pipeline from its file alone (FailOnBinaryArchiveMiss)");
            printf("     both from the archive in %.2f ms\n", ms);
        }
        return fails ? 1 : 0;
    }
}
