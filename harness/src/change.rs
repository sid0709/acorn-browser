//! Telling whether the page changed between two looks without a model reading either.
//!
//! A screenshot is reduced to a small grid of brightness values. Two grids whose every cell
//! differs by less than a threshold show the same page: a blinking caret or JPEG noise moves a
//! cell by a few points, while typed text, a new message, or a new page moves some cell by far
//! more. The largest cell, not the mean, is compared, so a small change in a big page is not
//! averaged away.

use base64::Engine;
use image::GenericImageView;

/// The side of the brightness grid a screenshot is reduced to.
pub const GRID_SIZE: usize = 32;
/// The largest brightness difference (0-255) any one cell may show for two screenshots to count
/// as the same page.
pub const UNCHANGED_BELOW: u8 = 12;
/// The most bytes one screenshot may hold.
pub const MAX_SCREENSHOT_BYTES: usize = 12 << 20;
/// How many pixels a screenshot may differ from the viewport it is sent with (a rounding of the
/// page's size).
pub const SIZE_TOLERANCE: u32 = 1;

/// A screenshot reduced to its brightness grid.
pub type Signature = Vec<u8>;

/// Reduces a screenshot (a data URL) to its signature, and reports the image's own size in
/// pixels, which the model's coordinates are measured in.
pub fn signature(data_url: &str) -> Result<(Signature, u32, u32), String> {
    let raw = decode_data_url(data_url)?;
    let img = image::load_from_memory(&raw).map_err(|e| format!("the screenshot is not a readable image: {e}"))?;
    let (width, height) = img.dimensions();
    Ok((grid(&img), width, height))
}

/// The size in pixels of an image data URL, read from its header without decoding the picture.
pub fn image_size(data_url: &str) -> Result<(u32, u32), String> {
    let raw = decode_data_url(data_url)?;
    image::ImageReader::new(std::io::Cursor::new(raw))
        .with_guessed_format()
        .map_err(|e| format!("the picture is not a readable image: {e}"))?
        .into_dimensions()
        .map_err(|e| format!("the picture is not a readable image: {e}"))
}

/// The bytes of an image data URL.
pub fn decode_data_url(data_url: &str) -> Result<Vec<u8>, String> {
    let comma = data_url.find(',');
    if !data_url.starts_with("data:image/") || comma.is_none() {
        return Err("the screenshot is not an image data URL".to_string());
    }
    let raw = base64::engine::general_purpose::STANDARD
        .decode(&data_url[comma.unwrap() + 1..])
        .map_err(|e| format!("the screenshot is not valid base64: {e}"))?;
    if raw.len() > MAX_SCREENSHOT_BYTES {
        return Err(format!("the screenshot is larger than {} MB", MAX_SCREENSHOT_BYTES >> 20));
    }
    Ok(raw)
}

/// The signature of a page known by its text alone (a look the browser could not photograph,
/// in DOM mode): the text's hash spread over the grid as full-contrast cells, so two texts that
/// differ differ in some cell by far more than the threshold, and the same text is the same.
pub fn text_signature(text: &str) -> Signature {
    let cells = GRID_SIZE * GRID_SIZE;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut out = Vec::with_capacity(cells);
    for byte in text.bytes().chain(std::iter::repeat(0).take(cells)) {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
        if out.len() < cells && (hash >> 32) & 1 == 1 {
            out.push(255);
        } else if out.len() < cells {
            out.push(0);
        }
    }
    out
}

/// Whether two signatures show the same page. An empty or mismatched signature never does.
pub fn unchanged(a: &[u8], b: &[u8]) -> bool {
    !a.is_empty() && a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.abs_diff(*y) < UNCHANGED_BELOW)
}

fn grid(img: &image::DynamicImage) -> Signature {
    let (width, height) = img.dimensions();
    let cells = GRID_SIZE * GRID_SIZE;
    if width == 0 || height == 0 {
        return vec![0; cells];
    }
    let luma = img.to_luma8();
    let mut sums = vec![0u64; cells];
    let mut counts = vec![0u64; cells];
    for (x, y, pixel) in luma.enumerate_pixels() {
        let cell = (y as usize * GRID_SIZE / height as usize) * GRID_SIZE + x as usize * GRID_SIZE / width as usize;
        sums[cell] += pixel.0[0] as u64;
        counts[cell] += 1;
    }
    sums.iter().zip(&counts).map(|(sum, count)| if *count > 0 { (sum / count) as u8 } else { 0 }).collect()
}

/// A PNG data URL of a plain image, with a darker square in its top left corner when `mark` is
/// set, for tests.
#[cfg(test)]
pub(crate) fn test_screenshot(width: u32, height: u32, mark: bool) -> String {
    use std::io::Cursor;
    let mut img = image::RgbImage::from_pixel(width, height, image::Rgb([240, 240, 240]));
    if mark {
        for y in 0..height / 2 {
            for x in 0..width / 2 {
                img.put_pixel(x, y, image::Rgb([20, 20, 20]));
            }
        }
    }
    let mut png = Vec::new();
    img.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
    format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_page_is_unchanged_and_a_marked_one_is_not() {
        let (plain, w, h) = signature(&test_screenshot(64, 48, false)).unwrap();
        let (again, _, _) = signature(&test_screenshot(64, 48, false)).unwrap();
        let (marked, _, _) = signature(&test_screenshot(64, 48, true)).unwrap();
        assert_eq!((w, h), (64, 48));
        assert_eq!(image_size(&test_screenshot(64, 48, false)).unwrap(), (64, 48));
        assert!(unchanged(&plain, &again));
        assert!(!unchanged(&plain, &marked));
        assert!(!unchanged(&[], &[]));
        assert!(signature("not a data url").is_err());
    }

    #[test]
    fn a_text_signature_tells_texts_apart_and_is_the_same_for_the_same_text() {
        let a = text_signature("VIEW y=0..800\nbutton[1] \"Go\"");
        let same = text_signature("VIEW y=0..800\nbutton[1] \"Go\"");
        let b = text_signature("VIEW y=0..800\nbutton[1] \"Stop\"");
        assert_eq!(a.len(), GRID_SIZE * GRID_SIZE);
        assert!(unchanged(&a, &same));
        assert!(!unchanged(&a, &b));
    }
}
