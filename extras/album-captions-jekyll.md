# Showing glickr captions on your Jekyll site

glickr writes per-item captions to `album.json` inside each album folder. **Your site ignores that
file today**, so captions you add in the app are stored correctly in your repo but render nowhere.

This is safe as-is: `album.json` sits two segments deep so the generator sees it, but it matches
neither the image nor the video extension list, so it is silently excluded from both the cover pick
and the gallery. Nothing breaks - the captions are just invisible.

To display them, apply the three changes below to `_plugins/albums.rb` and one to
`_layouts/album.html` in your site repo.

---

## 1. Add a caption reader to `Albums::Helpers`

The polymorphic value handling matters: glickr writes a bare string in the common case so the file
stays hand-editable, and only uses the object form when there is more than a caption to store.

```ruby
# Inside `module Helpers`, alongside strip_front_matter / http_get.

# Parse an album.json produced by glickr into { filename => caption }.
# Values are polymorphic: "0001.jpg": "text" in the common case, or
# "0001.jpg": {"caption": "text", ...} when extra keys are present.
# Never raises - a hand-mangled file should cost captions, not the build.
def self.parse_captions(raw)
  return {} if raw.nil? || raw.strip.empty?
  data = JSON.parse(raw)
  return {} unless data.is_a?(Hash)
  items = data["items"]
  return {} unless items.is_a?(Hash)

  items.each_with_object({}) do |(name, value), out|
    caption =
      case value
      when String then value
      when Hash   then value["caption"]
      end
    out[name] = caption if caption.is_a?(String) && !caption.empty?
  end
rescue StandardError => e
  Jekyll.logger.warn "Albums:", "bad album.json: #{e.message}"
  {}
end
```

## 2. Merge captions into remote albums

In `generate_remote`, just after the existing `album.md` block (the one that assigns `blurb`), add
the matching fetch for `album.json`:

```ruby
captions = {}
if names.include?("album.json")
  raw_json = Helpers.http_get("https://raw.githubusercontent.com/#{repo}/#{ref}/#{folder}/album.json") ||
             Helpers.http_get("#{cdn}/#{folder}/album.json")
  captions = Helpers.parse_captions(raw_json)
end
```

Then extend the item hash in the same method - it currently builds `{"url" =>, "video" =>}`:

```ruby
items = gallery.map do |f|
  {
    "url"     => enc.call(f),
    "video"   => VIDEO_EXT.include?(File.extname(f).downcase),
    "caption" => captions[f],
  }
end
```

## 3. Merge captions into local albums

`generate_local` builds items the same way, from `assets/albums/<folder>/`. Add:

```ruby
captions_path = File.join(dir, "album.json")
captions = File.exist?(captions_path) ? Helpers.parse_captions(File.read(captions_path)) : {}
```

and give its `items` map the same `"caption" => captions[f]` key.

## 4. Render them in `_layouts/album.html`

Wrap each grid item in a `<figure>` so the caption is associated with the image for assistive
technology, and use it as the `alt` text when present - a real caption is always better alt text
than "Cycling Trip photo 4".

```liquid
{% for item in page.images %}
  <figure class="photo-figure">
    {% if item.video %}
    <a href="{{ item.url }}" class="photo-item is-video" data-lightbox data-video
       aria-label="{{ item.caption | default: page.title | append: ' video' }}">
      <video src="{{ item.url }}" preload="metadata" muted playsinline></video>
      <span class="play-badge" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>
      </span>
    </a>
    {% else %}
    <a href="{{ item.url }}" class="photo-item" data-lightbox>
      <img src="{{ item.url }}"
           alt="{{ item.caption | default: page.title | append: ' photo' }}"
           loading="lazy">
    </a>
    {% endif %}
    {% if item.caption %}<figcaption>{{ item.caption }}</figcaption>{% endif %}
  </figure>
{% endfor %}
```

`.photo-grid` currently lays out `.photo-item` children directly, so add a rule letting the new
`figure` take that place, for example:

```css
.photo-grid > .photo-figure { margin: 0; display: flex; flex-direction: column; }
.photo-figure figcaption { font-size: .8rem; opacity: .7; padding: .35rem .1rem 0; }
```

---

## Notes

- `require "json"` is already at the top of `albums.rb`, so no new require is needed.
- Captions are keyed by filename. glickr removes an entry in the same commit that removes its file,
  and keeps a monotonic `next` counter so a deleted photo's number is never reissued - together
  those mean a caption can't end up attached to the wrong photo.
- If you edit `album.json` by hand, keep one entry per line. glickr writes it that way on purpose so
  that two devices captioning different photos merge cleanly in git instead of conflicting.
