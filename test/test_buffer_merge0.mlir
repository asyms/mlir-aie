// RUN: aie-opt --aie-merge-buffers %s | FileCheck %s

//CHECK-LABEL: module @test_buffer_merge0 {
//CHECK-NEXT: %0 = AIE.tile(3, 3)
//CHECK-NEXT: %1 = AIE.lock(%0, 0)
//CHECK-NEXT: %2 = AIE.tile(3, 4)
//CHECK-NEXT: %3 = AIE.tile(3, 2)
//CHECK-NEXT: %4 = AIE.lock(%2, 0)
//CHECK-NEXT: %5 = AIE.lock(%3, 0)
//CHECK-NEXT: %6 = AIE.buffer(%0) : memref<256xi32>
//CHECK-NEXT: %7 = AIE.buffer(%2) : memref<256xi32>
//CHECK-NEXT: %8 = AIE.buffer(%3) : memref<256xi32>
//CHECK-NEXT: %9 = AIE.mem(%2) {
//CHECK-NEXT:   AIE.terminator(^bb1)
//CHECK-NEXT:   ^bb1:  // pred: ^bb0
//CHECK-NEXT:     AIE.end
//CHECK-NEXT: }
//CHECK-NEXT: %10 = AIE.mem(%3) {
//CHECK-NEXT:   AIE.terminator(^bb1)
//CHECK-NEXT:   ^bb1:  // pred: ^bb0
//CHECK-NEXT:     AIE.end
//CHECK-NEXT: }
//CHECK-NEXT: %11 = AIE.core(%2) {
//CHECK-NEXT:   AIE.useLock(%1, "Acquire", 0, 0)
//CHECK-NEXT:   %c16 = constant 16 : index
//CHECK-NEXT:   %c1_i32 = constant 1 : i32
//CHECK-NEXT:   store %c1_i32, %6[%c16] : memref<256xi32>
//CHECK-NEXT:   AIE.useLock(%1, "Release", 1, 0)
//CHECK-NEXT:   AIE.end
//CHECK-NEXT: }
//CHECK-NEXT: %12 = AIE.core(%3) {
//CHECK-NEXT:   AIE.useLock(%1, "Acquire", 1, 0)
//CHECK-NEXT:   %c16 = constant 16 : index
//CHECK-NEXT:   %c1_i32 = constant 1 : i32
//CHECK-NEXT:   %16 = load %6[%c16] : memref<256xi32>
//CHECK-NEXT:   AIE.useLock(%1, "Release", 0, 0)
//CHECK-NEXT:   AIE.end
//CHECK-NEXT: }
//CHECK-NEXT: %13 = AIE.switchbox(%2) {
//CHECK-NEXT: }
//CHECK-NEXT: %14 = AIE.switchbox(%0) {
//CHECK-NEXT: }
//CHECK-NEXT: %15 = AIE.switchbox(%3) {
//CHECK-NEXT: }
//CHECK-NEXT: }

// In this simple test, we would like to merge buf34_0 and buf32_0 because:
//   - they are not used by cores other than core(3, 4) and core(3, 2), respectively (single user)
//   - core(3, 4) and core(3, 2) are distant (not abut)
//   - core(3, 4) uses DMA to copy data from buf34_0 to buf32_0 of core(3, 2)
//   - core(3, 4) and core(3, 2) has a shareable memory module: mem(3, 3)
//   - we want to avoid the overhead of DMA copy, and the routing resource that routes (3, 4) to (3, 2)
// After merging, the shared buf lives in mem(3, 3) that is accessed by core(3, 4), and then core(3, 2).
// Therefore, the functionality of the original netlist is still preserved.
// Merging Procedure:
//   1. Find bufs that have sharing opportunities
//   2. Find common (shareable) tile for the buf users (cores)
//   3. Create a BufferOp of that tile, and create a LockOp of that tile
//   4. Replace the usage of old buffers with the newly created buffer
//   5. Replace the usage of old locks (that guarded the old buffers) with the newly created lock
//   6. Remove the associated DMA operations (or Block Descriptors)
//   7. Remove the associated routing ConnectOps for the DMA operations
module @test_buffer_merge0 {
  %t33 = AIE.tile(3, 3)
  %t34 = AIE.tile(3, 4)
  %t32 = AIE.tile(3, 2)

  %l34_0 = AIE.lock(%t34, 0)
  %l32_0 = AIE.lock(%t32, 0)

  %buf34_0 = AIE.buffer(%t34) : memref<256xi32>
  %buf32_0 = AIE.buffer(%t32) : memref<256xi32>

  %m34 = AIE.mem(%t34) {
    %dmaSt = AIE.dmaStart("MM2S0")
    AIE.terminator(^dma0, ^end)
    ^dma0:
      cond_br %dmaSt, ^bd0, ^end
    ^bd0:
      AIE.useLock(%l34_0, "Acquire", 1, 0)
      AIE.dmaBd(<%buf34_0 : memref<256xi32>, 0, 256>, 0)
      AIE.useLock(%l34_0, "Release", 0, 0)
      br ^end
    ^end:
      AIE.end
  }

  %m32 = AIE.mem(%t32) {
    %dmaSt = AIE.dmaStart("S2MM0")
    AIE.terminator(^dma0, ^end)
    ^dma0:
      cond_br %dmaSt, ^bd0, ^end
    ^bd0:
      AIE.useLock(%l32_0, "Acquire", 0, 0)
      AIE.dmaBd(<%buf32_0 : memref<256xi32>, 0, 256>, 0)
      AIE.useLock(%l32_0, "Release", 1, 0)
      br ^end
    ^end:
      AIE.end
  }

  %c34 = AIE.core(%t34) {
    AIE.useLock(%l34_0, "Acquire", 0, 0)
    %i = constant 16 : index
    %0 = constant 1 : i32
    store %0, %buf34_0[%i] : memref<256xi32>
    AIE.useLock(%l34_0, "Release", 1, 0)
    AIE.end
  }

  %c32 = AIE.core(%t32) {
    AIE.useLock(%l32_0, "Acquire", 1, 0)
    %i = constant 16 : index
    %0 = constant 1 : i32
    %1 = load %buf32_0[%i] : memref<256xi32>
    AIE.useLock(%l32_0, "Release", 0, 0)
    AIE.end
  }

  %s34 = AIE.switchbox(%t34) {
    AIE.connect<"DMA": 0, "South": 0>
  }

  %s33 = AIE.switchbox(%t33) {
    AIE.connect<"North": 0, "South": 0>
  }

  %s32 = AIE.switchbox(%t32) {
    AIE.connect<"North": 0, "DMA": 0>
  }
}
