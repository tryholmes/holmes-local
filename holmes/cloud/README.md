# Holmes cloud

Everything Holmes sends off the Mac lives in one Appwrite Cloud project (`holmes`, region San Francisco).

| Piece | Where it runs | What it does |
|---|---|---|
| `functions/download` | https://holmes-download.appwrite.network | The website's Download buttons open this. It records the click (country, referrer, browser) in the `downloads` table, then redirects to the GitHub releases page. Crawlers are redirected but not counted. |
| `functions/track` | Called by the app through the Appwrite SDK | `install` events keep one row per Mac in `installs` (Holmes version, macOS version, Mac model, Region setting, country, first and last seen, launches). `signin` events also keep one row per account in `users`, reading the email and name from the verified Appwrite account, never from the request. |
| `dashboard` | https://holmes-analytics.appwrite.network | Admin analytics: downloads, installs, users, regions, versions, GitHub release totals, and the list of people with their email and region. Sign in with an emailed code; only members of the `admins` team can see data. |

## Data and access

* Database `holmes` with tables `downloads`, `installs`, and `users`. Each table grants read to `team:admins` only; nothing is readable or writable by the app or the public directly. The functions write with the per execution key Appwrite provides.
* Country comes from Appwrite's country header when present, otherwise from a short lookup of the caller's IP at country.is. The app separately reports the Mac's Region setting.
* Add an admin by adding their account to the `admins` team in the Appwrite console.

## Deploying

Each folder is deployed as is. Functions use the Node 22 runtime with entrypoint `src/main.js` and build command `npm install`. The dashboard is a static site served from its folder root.
