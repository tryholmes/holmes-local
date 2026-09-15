import { Client, TablesDB, Users, ID } from 'node-appwrite';

// Holmes calls this on launch ("install") and after signing in ("signin").
// The email always comes from the verified Appwrite account, never the body.
const DATABASE_ID = 'holmes';
const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const clip = (value, max) => {
  if (value === undefined || value === null) return null;
  const text = String(value).trim().slice(0, max);
  return text.length > 0 ? text : null;
};

// Same fallback as the download counter: Appwrite's country header when it is
// present, otherwise a short country.is lookup of the caller's IP.
async function countryFor(headers) {
  const known = clip(headers['x-appwrite-country-code'], 8);
  if (known) return known.toUpperCase();
  const ip = String(headers['fastly-client-ip'] ?? headers['x-cdn-client-ip'] ?? headers['x-real-ip']
    ?? headers['x-appwrite-client-ip'] ?? headers['x-forwarded-for'] ?? '').split(',')[0].trim();
  if (!ip) return null;
  try {
    const response = await fetch(`https://api.country.is/${encodeURIComponent(ip)}`, { signal: AbortSignal.timeout(1500) });
    if (!response.ok) return null;
    const { country } = await response.json();
    return clip(country, 8);
  } catch {
    return null;
  }
}

function parseBody(req) {
  if (req.bodyJson && typeof req.bodyJson === 'object') return req.bodyJson;
  const raw = req.bodyText ?? req.body ?? '';
  if (typeof raw === 'object' && raw !== null) return raw;
  return raw ? JSON.parse(raw) : {};
}

// Creates the row the first time and updates it afterwards, so first seen and
// sign up dates are kept while counters and versions move forward.
async function upsert(db, tableId, rowId, build) {
  let existing = null;
  try {
    existing = await db.getRow({ databaseId: DATABASE_ID, tableId, rowId });
  } catch (err) {
    if (err.code !== 404) throw err;
  }
  const data = build(existing);
  return existing
    ? db.updateRow({ databaseId: DATABASE_ID, tableId, rowId, data })
    : db.createRow({ databaseId: DATABASE_ID, tableId, rowId, data });
}

export default async ({ req, res, error }) => {
  if (req.method !== 'POST') return res.json({ ok: false, error: 'Send a POST request.' }, 405);

  let body;
  try {
    body = parseBody(req);
  } catch {
    return res.json({ ok: false, error: 'The request body must be JSON.' }, 400);
  }

  const event = body.event;
  if (event !== 'install' && event !== 'signin') {
    return res.json({ ok: false, error: 'event must be install or signin.' }, 400);
  }
  const installId = String(body.install_id ?? '').toLowerCase();
  if (!INSTALL_ID.test(installId)) {
    return res.json({ ok: false, error: 'install_id must be a UUID.' }, 400);
  }

  const headers = req.headers ?? {};
  const userId = clip(headers['x-appwrite-user-id'], 36);
  if (event === 'signin' && !userId) {
    return res.json({ ok: false, error: 'Sign in before sending a signin event.' }, 401);
  }

  const client = new Client()
    .setEndpoint(process.env.APPWRITE_FUNCTION_API_ENDPOINT)
    .setProject(process.env.APPWRITE_FUNCTION_PROJECT_ID)
    .setKey(headers['x-appwrite-key'] ?? '');
  const db = new TablesDB(client);
  const now = new Date().toISOString();

  const device = {
    holmes_version: clip(body.holmes_version, 32),
    macos_version: clip(body.macos_version, 32),
    mac_model: clip(body.mac_model, 64),
    region: clip(body.region, 8),
    country: await countryFor(headers),
  };

  try {
    await upsert(db, 'installs', installId, (existing) => ({
      ...device,
      locale: clip(body.locale, 32),
      last_seen: now,
      launches: (existing?.launches ?? 0) + 1,
      ...(existing ? {} : { first_seen: now }),
    }));

    if (event === 'signin') {
      const user = await new Users(client).get(userId);
      let isNewAccount = false;
      await upsert(db, 'users', userId, (existing) => {
        isNewAccount = !existing;
        return {
          ...device,
          email: clip(user.email, 320),
          name: clip(user.name, 128),
          install_id: installId,
          last_sign_in_at: now,
          sign_ins: (existing?.sign_ins ?? 0) + 1,
          ...(existing ? {} : { signed_up_at: user.$createdAt ?? now }),
        };
      });
      // One row per sign in, so the dashboard can chart sign ins per day.
      await db.createRow({
        databaseId: DATABASE_ID,
        tableId: 'sign_ins',
        rowId: ID.unique(),
        data: {
          user_id: userId,
          new_account: isNewAccount,
          region: device.region,
          country: device.country,
          holmes_version: device.holmes_version,
          macos_version: device.macos_version,
        },
      });
    }

    return res.json({ ok: true });
  } catch (err) {
    error(`Could not record the ${event} event: ${err.message}`);
    return res.json({ ok: false, error: 'Holmes could not record this event.' }, 500);
  }
};
