fn valid_hex(v: &str) -> bool {
    v.len() == 7 && v.starts_with('#') && v.as_bytes().iter().skip(1).all(u8::is_ascii_hexdigit)
}
fn complete_appearance(value: &serde_json::Value) -> bool {
    let text =
        |key: &str, limit: usize, empty: bool| value.get(key).and_then(|v| v.as_str()).is_some_and(|s| s.len() <= limit && (empty || !s.trim().is_empty()));
    let probability = |key: &str| value.get(key).and_then(|v| v.as_f64()).is_some_and(|v| v.is_finite() && (0.0..=1.0).contains(&v));
    text("id", 64, false)
        && value["id"].as_str().is_some_and(|s| s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'))
        && text("outfit", 128, true)
        && text("evidence", 1000, false)
        && probability("confidence")
        && probability("outfit_confidence")
        && value.get("bbox").and_then(|v| v.as_array()).is_some_and(|a| a.len() == 4 && a.iter().all(|v| v.as_u64().is_some_and(|n| n <= 1000)))
}
#[allow(dead_code)] // Only the CPU/vision helper parses model responses.
pub fn parse_assignment(text: &str) -> Result<serde_json::Value, String> {
    if text.len() > 128000 {
        return Err("Assignment response exceeds 128KB".into());
    }
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(value) if value.get("people").and_then(|v| v.as_array()).is_some_and(|a| a.len() <= 64 && a.iter().all(complete_appearance)) => Ok(value),
        Ok(_) => Err("Assignment must contain at most 64 complete appearance objects with identity, confidence, outfit, bbox and evidence".into()),
        Err(error) => {
            // Recover only fully parsed array objects; never close braces or
            // invent fields in a truncated appearance. Human review is retained.
            let root = text.trim().strip_prefix('{').ok_or_else(|| error.to_string())?;
            let rest = root
                .trim()
                .strip_prefix("\"people\"")
                .and_then(|s| s.trim_start().strip_prefix(':'))
                .and_then(|s| s.trim_start().strip_prefix('['))
                .ok_or_else(|| error.to_string())?;
            let mut remaining = rest;
            let mut people = Vec::new();
            for _ in 0..64 {
                let mut stream = serde_json::Deserializer::from_str(remaining.trim_start()).into_iter::<serde_json::Value>();
                match stream.next() {
                    Some(Ok(mut value)) if complete_appearance(&value) => {
                        let offset = stream.byte_offset();
                        remaining = remaining.trim_start().get(offset..).ok_or("Invalid response offset")?;
                        value["recovered_requires_confirmation"] = serde_json::json!(true);
                        value["identity_confirmed"] = serde_json::json!(false);
                        people.push(value);
                        if let Some(rest) = remaining.trim_start().strip_prefix(',') {
                            remaining = rest;
                        } else {
                            break;
                        }
                    }
                    _ => break,
                }
            }
            if people.is_empty() {
                return Err(format!("No complete appearance objects: {error}"));
            }
            Ok(
                serde_json::json!({"people":people,"partial_response":true,"review_warning":"Truncated model response: only complete appearance objects recovered; inspect remaining appearances manually","parse_error":error.to_string()}),
            )
        }
    }
}
pub fn matched_profile_instructions(style: &str, assigned: &serde_json::Value, people: &[serde_json::Value]) -> String {
    let mut instruction = style.to_owned();
    for matched in assigned.get("people").and_then(|v| v.as_array()).into_iter().flatten() {
        if matched["recovered_requires_confirmation"] == true && matched["identity_confirmed"] != true {
            continue;
        }
        let probability = matched.get("confidence").and_then(|v| v.as_f64()).unwrap_or(0.);
        if !(0.95..=1.).contains(&probability) {
            continue;
        }
        let id = matched.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if let Some(person) = people.iter().find(|p| p.get("id").and_then(|v| v.as_str()) == Some(id)) {
            if let Some(bounds) = matched.get("source_bbox") {
                instruction.push_str(&format!("\nAppearance {} at original-page xywh {bounds}: ", matched["appearance_id"]));
            }
            instruction.push_str(&format!("\nExisting character {id}, identified as {}: hair {}; both irises {}; consistent skin base {}. Keep original eye shapes, including closed eyes. Reuse these identity colors on EVERY identified appearance of this same person, including small insets. Do not change colors by panel scale. ",person.get("identify").and_then(|v|v.as_str()).unwrap_or(""),person.get("hair").and_then(|v|v.as_str()).unwrap_or(""),person.get("eyes").and_then(|v|v.as_str()).unwrap_or(""),person.get("skin").and_then(|v|v.as_str()).unwrap_or("")));
            if let Some(tones) = person.get("skin_tones").and_then(|v| v.as_object()) {
                for key in ["base", "shadow", "highlight", "undertone"] {
                    if let Some(color) = tones.get(key).and_then(|v| v.as_str()).filter(|c| valid_hex(c)) {
                        instruction.push_str(&format!("Established skin {key} {color}. "));
                    }
                }
            }
            if let Some(colors) = person.get("region_colors").and_then(|v| v.as_array()) {
                for entry in colors.iter().take(32) {
                    if let (Some(name), Some(color)) = (entry.get("name").and_then(|v| v.as_str()), entry.get("color").and_then(|v| v.as_str()))
                        && name.len() <= 80
                        && valid_hex(color)
                    {
                        instruction.push_str(&format!("Existing matching region {name} uses {color}; do not create regions. "));
                    }
                }
            }
            let outfit_confidence = matched.get("outfit_confidence").and_then(|v| v.as_f64()).unwrap_or(probability);
            let selected_outfit = if (0.95..=1.).contains(&outfit_confidence) { matched.get("outfit").and_then(|v| v.as_str()).unwrap_or("") } else { "" };
            for outfit in person.get("outfits").and_then(|v| v.as_array()).into_iter().flatten().filter(|o| {
                !selected_outfit.is_empty()
                    && (o.get("name").and_then(|v| v.as_str()) == Some(selected_outfit) || o.get("id").and_then(|v| v.as_str()) == Some(selected_outfit))
            }) {
                instruction.push_str(&format!(
                    "When the EXISTING outfit matches {}, use {}. Do not add or change garments. ",
                    outfit.get("identify").and_then(|v| v.as_str()).unwrap_or(""),
                    outfit.get("colors").and_then(|v| v.as_str()).unwrap_or("")
                ));
                for garment in outfit.get("garments").and_then(|v| v.as_array()).into_iter().flatten().take(32) {
                    if let (Some(id), Some(features), Some(color)) = (garment["id"].as_str(), garment["identify"].as_str(), garment["color"].as_str())
                        && valid_hex(color)
                    {
                        instruction.push_str(&format!("Approved garment {id}, identified by {features}: base {color}; preserve existing folds and pattern. Only apply if this garment is visible; do not add removed layers. "));
                    }
                }
            }
        }
    }
    instruction
}

/// Model coordinates are normalized xyxy in the provided source crop. Invalid
/// boxes remain review-only and never acquire a fabricated pixel mask.
pub fn locate(assigned: &mut serde_json::Value, crop: [u32; 4]) {
    if let Some(people) = assigned.get_mut("people").and_then(|v| v.as_array_mut()) {
        for (index, p) in people.iter_mut().enumerate() {
            if !p.is_object() {
                continue;
            }
            p["appearance_id"] = serde_json::json!(format!("appearance-{}-{}-{index}", crop[0], crop[1]));
            let box_values =
                p["bbox"].as_array().filter(|a| a.len() == 4).and_then(|a| a.iter().map(|v| v.as_u64().filter(|v| *v <= 1000)).collect::<Option<Vec<_>>>());
            if let Some(b) = box_values
                && b[0] < b[2]
                && b[1] < b[3]
            {
                let x = u64::from(crop[0]) + b[0] * u64::from(crop[2]) / 1000;
                let y = u64::from(crop[1]) + b[1] * u64::from(crop[3]) / 1000;
                let right = u64::from(crop[0]) + (b[2] * u64::from(crop[2])).div_ceil(1000);
                let bottom = u64::from(crop[1]) + (b[3] * u64::from(crop[3])).div_ceil(1000);
                p["source_bbox"] = serde_json::json!([x, y, right - x, bottom - y]);
                p["coordinate_space"] = serde_json::json!("original_pixels_xywh");
                p["precise_mask_available"] = serde_json::json!(false);
            } else {
                p["confidence"] = serde_json::json!(0.);
                p["source_bbox"] = serde_json::Value::Null;
                p["review_reason"] = serde_json::json!("Missing or invalid normalized crop bbox; no reliable spatial assignment");
            }
        }
    }
}
#[allow(dead_code)] // The GUI and CPU helper share this file; only the helper resolves repair keys.
pub fn palette(profiles: &serde_json::Value, key: &str) -> Option<String> {
    let parts: Vec<_> = key.split('/').collect();
    let person = profiles["characters"].as_array()?.iter().find(|p| p["id"].as_str() == parts.first().copied())?;
    let field = parts.get(1).copied()?;
    let text = if parts.len() == 4 && field == "outfit" {
        let outfit = person["outfits"].as_array()?.iter().find(|o| o["id"].as_str() == parts.get(2).copied() || o["name"].as_str() == parts.get(2).copied())?;
        outfit["garments"].as_array()?.iter().find(|g| g["id"].as_str() == parts.get(3).copied())?["color"].as_str()?
    } else if parts.len() == 2 && matches!(field, "hair" | "eyes" | "skin") {
        person[field].as_str()?
    } else if parts.len() == 2 && matches!(field, "Base" | "Shadow" | "Highlight" | "Undertone") {
        person["skin_tones"][field.to_lowercase()].as_str()?
    } else if parts.len() == 2 {
        person["region_colors"].as_array()?.iter().find(|r| r["name"].as_str() == Some(field))?["color"].as_str()?
    } else {
        return None;
    };
    text.as_bytes().windows(7).find_map(|b| std::str::from_utf8(b).ok().filter(|s| valid_hex(s)).map(str::to_owned))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn truncated_assignment_recovers_only_complete_objects() {
        let partial =
            r#"{"people":[{"id":"p1","bbox":[0,0,100,200],"confidence":1,"outfit":"","outfit_confidence":0,"evidence":"round glasses"},{"id":"p2","bbox":["#;
        let recovered = parse_assignment(partial).unwrap();
        assert_eq!(recovered["people"].as_array().unwrap().len(), 1);
        assert_eq!(recovered["people"][0]["id"], "p1");
        assert_eq!(recovered["partial_response"], true);
        let profiles = vec![serde_json::json!({"id":"p1","hair":"#123456","identify":"round glasses"})];
        assert!(matched_profile_instructions("", &recovered, &profiles).is_empty());
        let mut confirmed = recovered.clone();
        confirmed["people"][0]["identity_confirmed"] = true.into();
        assert!(matched_profile_instructions("", &confirmed, &profiles).contains("#123456"));
        assert!(parse_assignment(r#"{"people":[{"id":"p1","bbox":[0,0,100,200],"confidence":1,"outfit":""},"#).is_err());
        assert!(parse_assignment(r#"{"people":[{"id":"unfinished"#).is_err());
        assert_eq!(parse_assignment(r#"{"people":[]}"#).unwrap()["people"], serde_json::json!([]));
    }
    #[test]
    fn repeated_identity_keeps_distinct_outfits_and_never_borrows_another_persons_outfit() {
        let profiles = vec![
            serde_json::json!({"id":"a","identify":"round glasses","hair":"#123456","outfits":[{"id":"casual","name":"Casual","colors":"pink shirt","garments":[{"id":"shirt","identify":"round neck","color":"#EEAABB"}]},{"id":"dress","name":"Dress","colors":"purple dress"}]}),
            serde_json::json!({"id":"b","outfits":[{"id":"foreign","colors":"FORBIDDEN"}]}),
        ];
        let result = matched_profile_instructions(
            "",
            &serde_json::json!({"people":[{"id":"a","confidence":1,"outfit":"casual"},{"id":"a","confidence":1,"outfit":"dress"},{"id":"a","confidence":1,"outfit":"foreign"}]}),
            &profiles,
        );
        assert!(result.contains("#EEAABB") && result.contains("purple dress") && !result.contains("FORBIDDEN"));
        assert_eq!(profiles[0]["outfits"][0]["garments"][0]["color"], "#EEAABB");
    }
    #[test]
    fn crop_coordinates_are_explicit_and_malformed_boxes_cannot_bind() {
        let mut assigned = serde_json::json!({"people":[{"bbox":[0,0,1000,1000],"confidence":1},{"bbox":[1000,0,10,30],"confidence":1}]});
        locate(&mut assigned, [37, 129, 811, 1337]);
        assert_eq!(assigned["people"][0]["source_bbox"], serde_json::json!([37, 129, 811, 1337]));
        assert_eq!(assigned["people"][1]["confidence"], 0.);
        assert!(assigned["people"][1]["source_bbox"].is_null());
    }
    #[test]
    fn garment_keys_are_scoped_to_the_character_and_outfit() {
        let profiles = serde_json::json!({"characters":[{"id":"a","hair":"natural #123456","outfits":[{"id":"casual","garments":[{"id":"shirt","color":"#EEAABB"}]}]},{"id":"b","outfits":[{"id":"casual","garments":[{"id":"shirt","color":"#334455"}]}]}]});
        assert_eq!(palette(&profiles, "a/outfit/casual/shirt").as_deref(), Some("#EEAABB"));
        assert_eq!(palette(&profiles, "b/outfit/casual/shirt").as_deref(), Some("#334455"));
        assert!(palette(&profiles, "a/outfit/unknown/shirt").is_none());
        let weak = serde_json::json!({"people":[{"id":"a","confidence":1,"outfit":"casual","outfit_confidence":0.4}]});
        let instruction = matched_profile_instructions("", &weak, profiles["characters"].as_array().unwrap());
        assert!(instruction.contains("#123456") && !instruction.contains("#EEAABB"));
    }
}
