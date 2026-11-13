// A signed distance field from a canvas's coverage, by the exact Euclidean distance transform
// of Felzenszwalb and Huttenlocher, with partly covered pixels placed at sub-pixel distance.
// The result is one byte per pixel: 128 on the outline, higher inside, lower outside.

const FAR = 1e20;

function transform1d(grid, offset, stride, length, f, v, z) {
    v[0] = 0;
    z[0] = -FAR;
    z[1] = FAR;
    f[0] = grid[offset];
    for (let q = 1, k = 0, s = 0; q < length; q += 1) {
        f[q] = grid[offset + q * stride];
        const q2 = q * q;
        do {
            const r = v[k];
            s = (f[q] - f[r] + q2 - r * r) / (q - r) / 2;
        } while (s <= z[k] && --k > -1);
        k += 1;
        v[k] = q;
        z[k] = s;
        z[k + 1] = FAR;
    }
    for (let q = 0, k = 0; q < length; q += 1) {
        while (z[k + 1] < q) {
            k += 1;
        }
        const r = v[k];
        grid[offset + q * stride] = f[r] + (q - r) * (q - r);
    }
}

function transform2d(grid, width, height) {
    const length = Math.max(width, height);
    const f = new Float64Array(length);
    const v = new Uint16Array(length);
    const z = new Float64Array(length + 1);
    for (let x = 0; x < width; x += 1) {
        transform1d(grid, x, width, height, f, v, z);
    }
    for (let y = 0; y < height; y += 1) {
        transform1d(grid, y * width, 1, width, f, v, z);
    }
}

export function signedDistance(rgba, width, height, radius) {
    const count = width * height;
    const outside = new Float64Array(count);
    const inside = new Float64Array(count);
    for (let index = 0; index < count; index += 1) {
        const coverage = rgba[index * 4 + 3] / 255;
        if (coverage >= 1) {
            outside[index] = 0;
            inside[index] = FAR;
        } else if (coverage <= 0) {
            outside[index] = FAR;
            inside[index] = 0;
        } else {
            const edge = coverage - 0.5;
            outside[index] = Math.max(0, -edge) ** 2;
            inside[index] = Math.max(0, edge) ** 2;
        }
    }
    transform2d(outside, width, height);
    transform2d(inside, width, height);
    const field = new Uint8Array(count);
    for (let index = 0; index < count; index += 1) {
        const distance = Math.sqrt(inside[index]) - Math.sqrt(outside[index]);
        field[index] = Math.max(0, Math.min(255, Math.round(128 + (distance / radius) * 127)));
    }
    return field;
}
