use crate::Result;
pub struct Raster {
    pub pixels: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub linear: bool,
}
fn pixel_count(width: u32, height: u32) -> Result<usize> {
    let count = (width as usize)
        .checked_mul(height as usize)
        .ok_or("Image too large")?;
    if width == 0 || height == 0 || width > 100_000 || height > 100_000 || count > 100_000_000 {
        return Err("Image dimensions exceed safe limits".into());
    }
    Ok(count)
}
fn allocate(size: usize) -> Result<Vec<u8>> {
    let mut data = Vec::new();
    data.try_reserve_exact(size)
        .map_err(|_| "Insufficient image memory")?;
    data.resize(size, 0);
    Ok(data)
}
fn premultiply(p: &mut [u8]) {
    for pixel in p.chunks_exact_mut(4) {
        let a = pixel[3] as u16;
        for c in &mut pixel[..3] {
            *c = ((*c as u16 * a + 127) / 255) as u8;
        }
    }
}
pub fn qoi(bytes: &[u8]) -> Result<Raster> {
    if bytes.len() < 22 || &bytes[..4] != b"qoif" {
        return Err("Invalid QOI header".into());
    }
    let width = u32::from_be_bytes(bytes[4..8].try_into().unwrap());
    let height = u32::from_be_bytes(bytes[8..12].try_into().unwrap());
    let count = pixel_count(width, height)?;
    if ![3, 4].contains(&bytes[12]) || bytes[13] > 1 {
        return Err("Unsupported QOI channels or color space".into());
    }
    if bytes[bytes.len() - 8..] != [0, 0, 0, 0, 0, 0, 0, 1] {
        return Err("Missing QOI end marker".into());
    }
    let mut pixels = allocate(count * 4)?;
    let mut cursor = 14;
    let mut pixel = [0u8, 0, 0, 255];
    let mut index = [[0u8; 4]; 64];
    let mut remaining = 0;
    let end = bytes.len() - 8;
    for n in 0..count {
        if remaining > 0 {
            remaining -= 1;
        } else {
            if cursor >= end {
                return Err("Truncated QOI data".into());
            }
            let tag = bytes[cursor];
            cursor += 1;
            match tag {
                0xfe => {
                    if cursor + 3 > end {
                        return Err("Truncated QOI RGB".into());
                    }
                    pixel[..3].copy_from_slice(&bytes[cursor..cursor + 3]);
                    cursor += 3;
                }
                0xff => {
                    if cursor + 4 > end {
                        return Err("Truncated QOI RGBA".into());
                    }
                    pixel.copy_from_slice(&bytes[cursor..cursor + 4]);
                    cursor += 4;
                }
                _ => match tag & 0xc0 {
                    0x00 => pixel = index[tag as usize & 63],
                    0x40 => {
                        for (c, shift) in [4, 2, 0].iter().enumerate() {
                            pixel[c] = pixel[c].wrapping_add(((tag >> shift) & 3).wrapping_sub(2));
                        }
                    }
                    0x80 => {
                        if cursor >= end {
                            return Err("Truncated QOI luma".into());
                        }
                        let second = bytes[cursor];
                        cursor += 1;
                        let g = (tag & 63).wrapping_sub(32);
                        pixel[0] = pixel[0]
                            .wrapping_add(g)
                            .wrapping_add((second >> 4).wrapping_sub(8));
                        pixel[1] = pixel[1].wrapping_add(g);
                        pixel[2] = pixel[2]
                            .wrapping_add(g)
                            .wrapping_add((second & 15).wrapping_sub(8));
                    }
                    _ => {
                        remaining = (tag & 63) as usize;
                        if remaining >= count - n {
                            return Err("QOI run exceeds image".into());
                        }
                    }
                },
            }
        }
        let hash = (pixel[0] as usize * 3
            + pixel[1] as usize * 5
            + pixel[2] as usize * 7
            + pixel[3] as usize * 11)
            % 64;
        index[hash] = pixel;
        pixels[n * 4..n * 4 + 4].copy_from_slice(&pixel);
    }
    if cursor != end {
        return Err("Unexpected QOI trailing data".into());
    }
    premultiply(&mut pixels);
    Ok(Raster {
        pixels,
        width,
        height,
        linear: bytes[13] == 1,
    })
}
fn le(bytes: &[u8], n: usize) -> usize {
    u16::from_le_bytes([bytes[n], bytes[n + 1]]) as usize
}
pub fn pcx(bytes: &[u8]) -> Result<Raster> {
    if bytes.len() < 128 || bytes[0] != 10 || bytes[2] != 1 {
        return Err("Invalid PCX header".into());
    }
    let width = le(bytes, 8)
        .checked_sub(le(bytes, 4))
        .and_then(|x| x.checked_add(1))
        .ok_or("Invalid PCX bounds")?;
    let height = le(bytes, 10)
        .checked_sub(le(bytes, 6))
        .and_then(|x| x.checked_add(1))
        .ok_or("Invalid PCX bounds")?;
    let count = pixel_count(width as u32, height as u32)?;
    let bits = bytes[3] as usize;
    let planes = bytes[65] as usize;
    let line = le(bytes, 66);
    if !((bits == 8 && (planes == 1 || planes == 3 || planes == 4))
        || (bits == 1 && (1..=4).contains(&planes))
        || (bits == 4 && planes == 1))
    {
        return Err("Unsupported PCX variant".into());
    }
    if line < (width * bits).div_ceil(8) {
        return Err("PCX row is narrower than image".into());
    }
    let row_bytes = line.checked_mul(planes).ok_or("Invalid PCX stride")?;
    if row_bytes
        .checked_mul(height)
        .is_none_or(|n| n > 400_000_000)
    {
        return Err("PCX workspace exceeds safe limit".into());
    }
    let palette_start = if bits == 8 && planes == 1 {
        let offset = bytes.len().checked_sub(769).ok_or("Missing PCX palette")?;
        if offset < 128 || bytes[offset] != 12 {
            return Err("Missing PCX palette".into());
        }
        Some(offset)
    } else {
        None
    };
    let end = palette_start.unwrap_or(bytes.len());
    let mut cursor = 128;
    let mut pixels = allocate(count * 4)?;
    let mut row = allocate(row_bytes)?;
    // Decode one row at a time; padded strides never allocate an entire second image.
    for y in 0..height {
        let mut x = 0;
        while x < row_bytes {
            if cursor >= end {
                return Err("Truncated PCX data".into());
            }
            let value = bytes[cursor];
            cursor += 1;
            let (repeat, value) = if value & 0xc0 == 0xc0 {
                let repeat = (value & 63) as usize;
                if repeat == 0 || cursor >= end {
                    return Err("Invalid PCX run".into());
                }
                let v = bytes[cursor];
                cursor += 1;
                (repeat, v)
            } else {
                (1, value)
            };
            if x + repeat > row_bytes {
                return Err("PCX run crosses row boundary".into());
            }
            row[x..x + repeat].fill(value);
            x += repeat;
        }
        for x in 0..width {
            let rgb = if bits == 8 && planes >= 3 {
                [row[x], row[line + x], row[line * 2 + x]]
            } else {
                let (index, palette) = if bits == 8 {
                    (row[x] as usize, palette_start.unwrap() + 1)
                } else if bits == 4 {
                    (
                        (if x % 2 == 0 {
                            row[x / 2] >> 4
                        } else {
                            row[x / 2] & 15
                        }) as usize,
                        16,
                    )
                } else {
                    let mut index = 0;
                    for p in 0..planes {
                        if row[p * line + x / 8] & (0x80 >> (x % 8)) != 0 {
                            index |= 1 << p;
                        }
                    }
                    (index, 16)
                };
                let base = palette + index * 3;
                [bytes[base], bytes[base + 1], bytes[base + 2]]
            };
            let base = (y * width + x) * 4;
            pixels[base..base + 3].copy_from_slice(&rgb);
            pixels[base + 3] = 255;
        }
    }
    Ok(Raster {
        pixels,
        width: width as u32,
        height: height as u32,
        linear: false,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    fn qoi_bytes() -> Vec<u8> {
        let mut b = b"qoif".to_vec();
        b.extend(1u32.to_be_bytes());
        b.extend(1u32.to_be_bytes());
        b.extend([4, 0, 0xff, 200, 100, 50, 128, 0, 0, 0, 0, 0, 0, 0, 1]);
        b
    }
    #[test]
    fn qoi_premultiplication() {
        assert_eq!(qoi(&qoi_bytes()).unwrap().pixels, [100, 50, 25, 128]);
    }
    #[test]
    fn damaged_qoi_rejected() {
        let mut b = qoi_bytes();
        b.truncate(18);
        assert!(qoi(&b).is_err());
        let mut b = qoi_bytes();
        b[4..8].copy_from_slice(&100_001u32.to_be_bytes());
        assert!(qoi(&b).is_err());
    }
    #[test]
    fn pcx_invalid_stride_rejected() {
        let mut b = vec![0; 128];
        b[0] = 10;
        b[2] = 1;
        b[3] = 8;
        b[8] = 10;
        b[65] = 3;
        b[66] = 1;
        assert!(pcx(&b).is_err());
    }
    #[test]
    fn pcx_rgb_and_corrupt_run() {
        let mut b = vec![0; 128];
        b[0] = 10;
        b[2] = 1;
        b[3] = 8;
        b[65] = 3;
        b[66] = 1;
        b.extend([10, 20, 30]);
        assert_eq!(pcx(&b).unwrap().pixels, [10, 20, 30, 255]);
        b.truncate(128);
        b.extend([0xc4, 1]);
        assert!(pcx(&b).is_err());
    }
}
