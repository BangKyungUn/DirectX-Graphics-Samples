//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author:  James Stanard 
//
// Description:  The bitonic sort works by sorting groups of size k,
// starting with k=2 and doubling until k>=NumItems.  To sort the
// group, keys are compared with a distance of j, which starts at half
// of k and continues halving down to 1.  When j is 1024 and less, the
// compare and swap can happen in LDS, and these iterations form the
// "inner sort".  Inner sorting happens in LDS and loops.  Outer sorting
// happens in memory and does not loop.  (Looping happens on the CPU by
// issuing sequential dispatches and barriers.)


#include "BitonicSortCommon.hlsli"

RWStructuredBuffer<uint2> g_SortBuffer : register(u0);

cbuffer Constants : register(b0)
{
    uint k; // k >= 4096
};

groupshared uint gs_SortKeys[2048];
groupshared uint gs_SortIndices[2048];

void LoadKeyIndexPair( uint GroupStart, uint Offset )
{
    uint2 KeyIndex = g_SortBuffer[GroupStart + Offset];
    gs_SortIndices[Offset] = KeyIndex.x;
    gs_SortKeys[Offset] = KeyIndex.y;
}

void StoreKeyIndexPair( uint GroupStart, uint Offset )
{
    uint2 KeyIndex = uint2(gs_SortIndices[Offset], gs_SortKeys[Offset]);
    g_SortBuffer[GroupStart + Offset] = KeyIndex;
}

[RootSignature(BitonicSort_RootSig)]
[numthreads(1024, 1, 1)]
void main( uint3 Gid : SV_GroupID, uint GI : SV_GroupIndex )
{
    // Item index of the start of this group
    const uint GroupStart = Gid.x * 2048;

    // Load from memory into LDS to prepare sort
    LoadKeyIndexPair(GroupStart, GI);
    LoadKeyIndexPair(GroupStart, GI + 1024);

    GroupMemoryBarrierWithGroupSync();

    // This is better unrolled because it reduces ALU and because some
    // architectures can load/store two LDS items in a single instruction
    // as long as their separation is a compile-time constant.
    [unroll]
    for (uint j = 1024; j > 0; j >>= 1)
    {
        uint Index1 = InsertZeroBit(GI, j);
        uint Index2 = Index1 | j;

        uint A = gs_SortKeys[Index1];
        uint B = gs_SortKeys[Index2];

        if (ShouldSwap(A, B, GroupStart, k))
        {
            // First swap the keys
            gs_SortKeys[Index1] = B;
            gs_SortKeys[Index2] = A;

            // Then swap the indices
            A = gs_SortIndices[Index1];
            B = gs_SortIndices[Index2];
            gs_SortIndices[Index1] = B;
            gs_SortIndices[Index2] = A;
        }

        GroupMemoryBarrierWithGroupSync();
    }

    StoreKeyIndexPair(GroupStart, GI);
    StoreKeyIndexPair(GroupStart, GI + 1024);
}