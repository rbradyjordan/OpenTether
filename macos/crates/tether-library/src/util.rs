//! `NSString` path helpers with the same edge cases as Foundation.

/// `lastPathComponent`: the part after the final `/` (trailing slashes ignored).
pub fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// Index of the extension dot in a file name, if it has one. A leading dot
/// (`.hidden`) is not an extension, like Foundation.
fn ext_dot(name: &str) -> Option<usize> {
    match name.rfind('.') {
        Some(0) | None => None,
        Some(i) if i + 1 == name.len() => None,
        Some(i) => Some(i),
    }
}

/// `deletingPathExtension` applied to a bare file name.
pub fn delete_path_extension(name: &str) -> &str {
    match ext_dot(name) {
        Some(i) => &name[..i],
        None => name,
    }
}

/// `pathExtension` of a bare file name (no dot), possibly empty.
pub fn path_extension(name: &str) -> &str {
    match ext_dot(name) {
        Some(i) => &name[i + 1..],
        None => "",
    }
}

/// `appendingPathComponent` for `/`-separated strings.
pub fn append_path(base: &str, component: &str) -> String {
    if base.is_empty() {
        return component.to_string();
    }
    let component = component.trim_start_matches('/');
    if base.ends_with('/') {
        format!("{base}{component}")
    } else {
        format!("{base}/{component}")
    }
}

/// Finder-style ordering (`localizedStandardCompare`): case-insensitive,
/// runs of digits compared by value.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (a, b) = (a.to_lowercase(), b.to_lowercase());
    let (mut ai, mut bi) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = ai.peek().copied().filter(char::is_ascii_digit) {
                    na.push(c);
                    ai.next();
                }
                let mut nb = String::new();
                while let Some(c) = bi.peek().copied().filter(char::is_ascii_digit) {
                    nb.push(c);
                    bi.next();
                }
                let ta = na.trim_start_matches('0');
                let tb = nb.trim_start_matches('0');
                let ord = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(x), Some(y)) => {
                if x != y {
                    return x.cmp(&y);
                }
                ai.next();
                bi.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foundation_edge_cases() {
        assert_eq!(delete_path_extension("IMG_0001.CR3"), "IMG_0001");
        assert_eq!(delete_path_extension(".hidden"), ".hidden");
        assert_eq!(delete_path_extension("a.b.c"), "a.b");
        assert_eq!(path_extension("A.CR3.xmp"), "xmp");
        assert_eq!(path_extension("noext"), "");
        assert_eq!(last_path_component("/a/b/c.jpg"), "c.jpg");
        assert_eq!(append_path("/", "a/b"), "/a/b");
        assert_eq!(append_path("/up", "a"), "/up/a");
        assert_eq!(natural_cmp("img2", "IMG10"), std::cmp::Ordering::Less);
    }
}
