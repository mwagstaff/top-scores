function normalizeTeamDisplayShortName(shortNameValue, fullNameValue) {
  const fullName = String(fullNameValue || "").trim();
  let shortName = String(shortNameValue || "").trim();
  if (!shortName || !fullName || shortName.localeCompare(fullName, undefined, { sensitivity: "accent" }) === 0) {
    return null;
  }

  if (/\bUnited\b/i.test(fullName) && /\sU$/i.test(shortName)) {
    shortName = `${shortName.slice(0, -1)}Utd`;
  }

  if (/^\p{Lu}{2,4}$/u.test(shortName)) {
    const firstFullNameToken = fullName.match(/[\p{L}\p{N}]+/u)?.[0] || "";
    const isLeadingName = firstFullNameToken.toUpperCase() === shortName;
    const isClubDesignator = /^(?:AFC|FC|CF|SC)$/.test(shortName);
    if (!isLeadingName || isClubDesignator) {
      return null;
    }
  }

  return shortName;
}

module.exports = {
  normalizeTeamDisplayShortName,
};
