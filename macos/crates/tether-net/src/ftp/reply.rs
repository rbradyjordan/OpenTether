//! FTP control replies and the PASV/EPSV parsers (`FTPReply` in `FTPClient.swift`).

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FtpReply {
    pub code: u16,
    pub lines: Vec<String>,
}

impl FtpReply {
    pub fn text(&self) -> String {
        self.lines.join("\n")
    }

    pub fn is_positive(&self) -> bool {
        (200..400).contains(&self.code)
    }

    pub fn is_preliminary(&self) -> bool {
        (100..200).contains(&self.code)
    }

    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`
    pub fn parse_pasv(text: &str) -> Option<(String, u16)> {
        if let Some(open) = text.rfind('(') {
            if let Some(close) = text[open..].find(')') {
                return Self::parse_pasv_numbers(&text[open + 1..open + close]);
            }
        }
        Self::parse_pasv_numbers(text)
    }

    fn parse_pasv_numbers(s: &str) -> Option<(String, u16)> {
        let nums: Vec<u32> = s
            .split(|c: char| !c.is_ascii_digit())
            .filter(|p| !p.is_empty())
            .filter_map(|p| p.parse().ok())
            .collect();
        if nums.len() < 6 {
            return None;
        }
        let n = &nums[nums.len() - 6..];
        if n.iter().any(|&v| v > 255) {
            return None;
        }
        Some((
            format!("{}.{}.{}.{}", n[0], n[1], n[2], n[3]),
            ((n[4] << 8) | n[5]) as u16,
        ))
    }

    /// `229 Entering Extended Passive Mode (|||port|)`
    pub fn parse_epsv(text: &str) -> Option<u16> {
        let open = text.rfind('(')?;
        let close = text[open..].find(')')?;
        let inner = &text[open + 1..open + close];
        let delim = inner.chars().next()?;
        let parts: Vec<&str> = inner.split(delim).collect();
        if parts.len() < 4 {
            return None;
        }
        parts[3].parse().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_parsers() {
        let p = FtpReply::parse_pasv("Entering Passive Mode (192,168,1,20,156,64)").unwrap();
        assert_eq!(p.0, "192.168.1.20");
        assert_eq!(p.1, (156 << 8) | 64);
        assert_eq!(
            FtpReply::parse_pasv("=10,0,0,1,0,21").map(|p| p.1),
            Some(21)
        );
        assert_eq!(FtpReply::parse_pasv("Entering Passive Mode (1,2,3)"), None);
        assert_eq!(
            FtpReply::parse_epsv("Entering Extended Passive Mode (|||40001|)"),
            Some(40001)
        );
        assert_eq!(FtpReply::parse_epsv("nope"), None);
        let r = FtpReply {
            code: 211,
            lines: vec!["Features:".into(), " UTF8".into(), "End".into()],
        };
        assert!(r.is_positive());
        let prelim = FtpReply {
            code: 150,
            lines: vec![],
        };
        assert!(!prelim.is_positive());
        assert!(prelim.is_preliminary());
    }
}
