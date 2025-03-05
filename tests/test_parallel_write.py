import asyncio

import httpx
import numpy
import pytest

from .util import assert_status


@pytest.mark.asyncio
async def test_parallel_write(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
):
    async def data_generator(chunk_bytes: int, num_chunks: int):
        rng = numpy.random.Generator(numpy.random.PCG64(seed=42))
        for i in range(num_chunks):
            yield rng.bytes(chunk_bytes)

    async with httpx.AsyncClient(
        base_url=nginx_server, headers=wlcg_create_header
    ) as client:

        async def run(i: int):
            response = await client.put(
                f"/test_chunks_{i:03d}.bin",
                headers=wlcg_create_header,
                content=data_generator(64 * 1024, 32),
            )
            assert_status(response, httpx.codes.CREATED)

        await asyncio.gather(*map(run, range(32)))
