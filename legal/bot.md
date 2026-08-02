# HollowBot

<!-- Canonical text. The PUBLISHED page is a SvelteKit route in the website
     repo: WholesomeStoryAday/!website/src/routes/bot/+page.svelte → served at
     https://anonlisten.com/bot . Edit both, or this drifts. -->

`Mozilla/5.0 (compatible; HollowBot/1.0; +https://anonlisten.com/bot)`

If you found this page in your access logs, someone using [Hollow](https://anonlisten.com)
pasted a link to your site into a chat message.

## What it does

When a Hollow user types a URL into the message box, their app fetches that
page once and reads its OpenGraph tags — title, description, and the preview
image — so the message can carry a preview card.

That is the whole behaviour:

- **One request per pasted link.** It is not a crawl. HollowBot does not follow
  links, does not walk your sitemap, and does not come back on a schedule.
- **Nothing is indexed or stored on our servers.** The title, description and a
  downscaled thumbnail are embedded in the user's encrypted message and travel
  to the people they are talking to. We never see them.
- **Recipients never contact your site.** They render the card from data that
  arrived inside the message. One paste means one request, no matter how many
  people read it.
- **It requests the page and its preview image. Nothing else.**

## Where the request comes from

The user's own device, not our infrastructure. Hollow is distributed and there
is no server in the middle fetching pages on anyone's behalf, so there is no IP
range to block — the address in your log belongs to a person who was reading
your page.

If you want to opt out, block on the User-Agent string. HollowBot sends it on
every request and does not vary it.

## robots.txt

HollowBot does not fetch robots.txt, and we would rather say so plainly than
imply a compliance we do not implement. The reasoning: this is a single
user-initiated unfurl of a link a person deliberately shared, not automated
crawling, which is the same position Slack and Discord take for their own
previews. Fetching robots.txt first would also mean two requests to your server
instead of one.

If you would prefer HollowBot did not fetch your pages, block the User-Agent, or
get in touch at [privacy@anonlisten.com](mailto:privacy@anonlisten.com) and we
will help.

## Turning it off as a user

Hollow users can disable link previews entirely in **Settings → Network → Link
Previews**. With it off, the app never touches a pasted URL at all.
