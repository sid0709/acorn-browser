//! Drawing where a plan's actions point on the screenshot the model was shown: for the decision
//! model that checks a point against its label, and for a person debugging a run. It shows,
//! without guessing, where a click actually went, and hides nothing of what is there.

use base64::Engine;
use image::RgbImage;

use crate::action::{Action, Kind};
use crate::change;

/// The JPEG quality of a screenshot with its actions drawn on it.
pub const MARKED_QUALITY: u8 = 85;

// The marker's shape, in screenshot pixels at scale 1. The ring is wide and open: a point sits on
// the control's own text (a short button, the line a value is typed on), and the decision model
// that checks the point against its label must still read that text. The number plate sits
// outside the ring, at its top right.
const RING_RADIUS: i32 = 24;
const DOT_RADIUS: i32 = 3;
const HALO_WIDTH: i32 = 2;
const PLATE_GAP: i32 = 4;

/// The digits 0-9, each 3 columns by 5 rows, so an action can be numbered on the screenshot
/// without a font library.
const DIGIT_FONT: [[&str; 5]; 10] = [
    ["###", "# #", "# #", "# #", "###"],
    [" # ", "## ", " # ", " # ", "###"],
    ["###", "  #", "###", "#  ", "###"],
    ["###", "  #", "###", "  #", "###"],
    ["# #", "# #", "###", "  #", "  #"],
    ["###", "#  ", "###", "  #", "###"],
    ["###", "#  ", "###", "# #", "###"],
    ["###", "  #", "  #", "  #", "  #"],
    ["###", "# #", "###", "# #", "###"],
    ["###", "# #", "###", "  #", "###"],
];

type Color = [u8; 3];
const CLICK: Color = [235, 30, 30];
const SCROLL: Color = [30, 90, 235];
const UPLOAD: Color = [20, 160, 60];
const HOVER: Color = [170, 60, 200];
const LABEL: Color = [255, 255, 0];
const HALO: Color = [255, 255, 255];
const PLATE: Color = [0, 0, 0];

/// Draws where each action points on the screenshot: an open ring with a dot at its middle for a
/// click or an upload, a ring for a hover, a line for a scroll, each numbered in order. Returns
/// the marked screenshot as a JPEG data URL.
pub fn mark_screenshot(data_url: &str, actions: &[Action]) -> Result<String, String> {
    let raw = change::decode_data_url(data_url)?;
    let mut canvas = image::load_from_memory(&raw).map_err(|e| format!("the screenshot is not a readable image: {e}"))?.to_rgb8();
    // Keep the marks legible on a wide screenshot; thin lines vanish in JPEG compression.
    let scale = (canvas.width() as i32 / 700).max(1);
    let thick = (2 * scale).max(3);
    let radius = RING_RADIUS * scale;
    for (i, action) in actions.iter().enumerate() {
        let (x, y) = match (&action.kind, action.point()) {
            (Kind::Scroll { x: Some(x), y: Some(y), .. }, _) => (*x as i32, *y as i32),
            (_, Some(point)) => (point.x as i32, point.y as i32),
            _ => continue,
        };
        match &action.kind {
            Kind::Scroll { dx, dy, .. } => {
                let limit = 160.0 * scale as f64;
                draw_line(&mut canvas, x, y, x + dx.clamp(-limit, limit) as i32, y + dy.clamp(-limit, limit) as i32, SCROLL, thick);
                draw_ring(&mut canvas, x, y, 6 * scale, SCROLL, thick);
            }
            Kind::Upload { .. } => draw_open_mark(&mut canvas, x, y, radius, scale, UPLOAD, thick),
            Kind::Hover { .. } => draw_ring(&mut canvas, x, y, radius, HOVER, thick),
            _ => draw_open_mark(&mut canvas, x, y, radius, scale, CLICK, thick),
        }
        let gap = PLATE_GAP * scale;
        draw_number(&mut canvas, i + 1, x + radius + thick + gap, y - radius - thick - gap - 6 * scale, scale, LABEL);
    }
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, MARKED_QUALITY)
        .encode_image(&canvas)
        .map_err(|e| format!("the marked screenshot could not be encoded: {e}"))?;
    Ok(format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(out)))
}

/// A point as a wide ring with a white halo outside it and a dot at its middle: what lies inside
/// the ring (a button's text, a field's value line) stays readable.
fn draw_open_mark(img: &mut RgbImage, cx: i32, cy: i32, radius: i32, scale: i32, c: Color, thickness: i32) {
    draw_ring(img, cx, cy, radius + thickness, HALO, HALO_WIDTH * scale);
    draw_ring(img, cx, cy, radius, c, thickness);
    draw_ring(img, cx, cy, 0, c, DOT_RADIUS * scale);
}

fn set(img: &mut RgbImage, x: i32, y: i32, c: Color) {
    if x >= 0 && y >= 0 && (x as u32) < img.width() && (y as u32) < img.height() {
        img.put_pixel(x as u32, y as u32, image::Rgb(c));
    }
}

fn draw_ring(img: &mut RgbImage, cx: i32, cy: i32, radius: i32, c: Color, thickness: i32) {
    for y in -radius - thickness..=radius + thickness {
        for x in -radius - thickness..=radius + thickness {
            let d = (x as f64).hypot(y as f64);
            if d >= radius as f64 && d <= (radius + thickness) as f64 {
                set(img, cx + x, cy + y, c);
            }
        }
    }
}

fn draw_line(img: &mut RgbImage, x0: i32, y0: i32, x1: i32, y1: i32, c: Color, thickness: i32) {
    let steps = (x1 - x0).abs().max((y1 - y0).abs());
    for i in 0..=steps {
        let f = i as f64 / (steps.max(1)) as f64;
        let (x, y) = (x0 + (f * (x1 - x0) as f64) as i32, y0 + (f * (y1 - y0) as f64) as i32);
        for t in 0..thickness {
            set(img, x + t, y, c);
            set(img, x, y + t, c);
        }
    }
}

/// A small number (a black box behind coloured digits) at the point.
fn draw_number(img: &mut RgbImage, n: usize, x: i32, y: i32, scale: i32, c: Color) {
    let digits: Vec<usize> = n.to_string().bytes().map(|b| (b - b'0') as usize).collect();
    let pixel = 3 * scale;
    let width = digits.len() as i32 * 4 * pixel + pixel;
    for yy in -pixel..6 * pixel {
        for xx in -pixel..width {
            set(img, x + xx, y + yy, PLATE);
        }
    }
    for (i, digit) in digits.iter().enumerate() {
        for (row, line) in DIGIT_FONT[*digit].iter().enumerate() {
            for (col, cell) in line.bytes().enumerate() {
                if cell != b'#' {
                    continue;
                }
                for dy in 0..pixel {
                    for dx in 0..pixel {
                        set(img, x + (i as i32 * 4 + col as i32) * pixel + dx, y + row as i32 * pixel + dy, c);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::GenericImageView;

    #[test]
    fn a_marked_screenshot_keeps_its_size_and_shows_the_point() {
        let click = Action::new("a", Kind::Click { x: 50.0, y: 50.0 });
        let marked = mark_screenshot(&change::test_screenshot(200, 100, false), &[click]).unwrap();
        assert!(marked.starts_with("data:image/jpeg;base64,"));
        let img = image::load_from_memory(&change::decode_data_url(&marked).unwrap()).unwrap();
        assert_eq!(img.dimensions(), (200, 100));
        let [r, g, b, _] = img.get_pixel(50, 50).0;
        assert!(r > 150 && g < 100 && b < 100, "the dot at the point is red, got {r},{g},{b}");
        assert!(mark_screenshot("not a data url", &[]).is_err());
    }
}
