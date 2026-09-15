import { Client, TablesDB, ID } from 'node-appwrite';

// Every Download button on the Holmes website points here. The click is
// recorded, then the visitor lands on the releases page to pick a version.
const RELEASES_URL = 'https://github.com/tryholmes/holmes-local/releases';

// Link previews and crawlers should still be redirected, but not counted.
const AUTOMATED_AGENT = /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|curl|wget|python|headless/i;

const clip = (value, max) => {
  if (value === undefined || value === null) return null;
  const text = String(value).trim().slice(0, max);
  return text.length > 0 ? text : null;
};

// Appwrite only fills the country header for some requests, so fall back to
// country.is (open source) using the visitor's IP. Never waits long.
async function countryFor(headers, log) {
  const known = clip(headers['x-appwrite-country-code'], 8);
  if (known) return known.toUpperCase();
  // The CDN puts the real visitor address in its own headers; x-forwarded-for can start with a proxy.
  const ip = String(headers['fastly-client-ip'] ?? headers['x-cdn-client-ip'] ?? headers['x-real-ip']
    ?? headers['x-appwrite-client-ip'] ?? headers['x-forwarded-for'] ?? '').split(',')[0].trim();
  if (!ip) {
    log('country lookup skipped: no client address header');
    return null;
  }
  try {
    const response = await fetch(`https://api.country.is/${encodeURIComponent(ip)}`, { signal: AbortSignal.timeout(2500) });
    if (!response.ok) {
      log(`country lookup failed: status ${response.status}`);
      return null;
    }
    const { country } = await response.json();
    return clip(country, 8);
  } catch (err) {
    log(`country lookup failed: ${err.name}`);
    return null;
  }
}

export default async ({ req, res, log, error }) => {
  const headers = req.headers ?? {};
  const agent = String(headers['user-agent'] ?? '');

  if (req.method === 'GET' && !AUTOMATED_AGENT.test(agent)) {
    try {
      const country = await countryFor(headers, log);
      const client = new Client()
        .setEndpoint(process.env.APPWRITE_FUNCTION_API_ENDPOINT)
        .setProject(process.env.APPWRITE_FUNCTION_PROJECT_ID)
        .setKey(headers['x-appwrite-key'] ?? '');

      await new TablesDB(client).createRow({
        databaseId: 'holmes',
        tableId: 'downloads',
        rowId: ID.unique(),
        data: {
          country,
          continent: clip(headers['x-appwrite-continent-code'], 8),
          referrer: clip(headers['referer'] ?? headers['referrer'], 512),
          user_agent: clip(agent, 512),
          source: clip(req.query?.source ?? 'website', 64),
        },
      });
    } catch (err) {
      // Never block the download because the counter failed.
      error(`Could not record the download: ${err.message}`);
    }
  }

  return res.redirect(RELEASES_URL, 302);
};
