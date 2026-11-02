# frozen_string_literal: true

require "cgi"
require "json"
require "tmpdir"

# A screen check of the kind a repository declares, with nothing to install: draws a page on two narrow screens in
# real Chrome, keeps each picture, and fails if any text runs past the screen's edge. Headless Chrome will not make a
# window narrower than 500, so the page goes in a frame the size of the screen.
module ScreenFit
  SCREENS = [[390, 844], [320, 568]].freeze
  CHROMES = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"].freeze
  MAC_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  # A range measures the text itself, which runs on past any box that holds it.
  MEASURE = <<~JS
    const frame = document.querySelector('iframe');
    frame.addEventListener('load', () => {
      const doc = frame.contentDocument, off = [];
      const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const text = walker.currentNode.textContent.trim();
        if (!text) continue;
        const range = doc.createRange(); range.selectNodeContents(walker.currentNode);
        const box = range.getBoundingClientRect();
        if (box.right > frame.clientWidth + .5 || box.left < -.5) off.push({ text, left: Math.round(box.left), right: Math.round(box.right) });
      }
      document.getElementById('fit').textContent = JSON.stringify(off);
    });
  JS

  module_function

  def chrome
    return MAC_CHROME if File.executable?(MAC_CHROME)
    CHROMES.find { |name| ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) } }
  end

  # The text off the screen, once a picture of the screen is at `picture`.
  def off_screen(page, width, height, picture)
    Dir.mktmpdir("screen-fit-") do |dir|
      wrapper = File.join(dir, "screen.html")
      File.write(wrapper, %(<!doctype html><meta charset="utf-8"><body style="margin:0"><iframe style="display:block;border:0;width:#{width}px;height:#{height}px" srcdoc="#{CGI.escapeHTML(page)}"></iframe><pre id="fit" hidden></pre><script>#{MEASURE}</script>))
      # No sandbox of its own: Chrome's cannot start inside the harness's, and Playwright turns it off the same way.
      flags = ["--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--user-data-dir=#{File.join(dir, 'profile')}", "--window-size=#{width},#{height}"]
      system(chrome, *flags, "--screenshot=#{picture}", "file://#{wrapper}", out: File::NULL, err: File::NULL) or abort("Chrome could not draw the page")
      dom = IO.popen([chrome, *flags, "--dump-dom", "file://#{wrapper}"], err: File::NULL, external_encoding: "UTF-8", &:read)
      found = dom[%r{<pre id="fit" hidden="">(.*?)</pre>}m, 1] or abort("Chrome did not measure the page")
      JSON.parse(CGI.unescapeHTML(found))
    end
  end

  def check(page_path, shots)
    page = File.read(page_path, encoding: "UTF-8")
    failed = false
    SCREENS.each do |width, height|
      off = off_screen(page, width, height, File.join(shots, "hud-#{width}.png"))
      failed ||= off.any?
      puts(off.empty? ? "ok   at #{width} wide all the text is on the screen" : "FAIL at #{width} wide: #{off.map { |row| "#{row['text'].inspect} ends at #{row['right']}" }.join(', ')}")
    end
    exit(failed ? 1 : 0)
  end
end

ScreenFit.check(ARGV.fetch(0), ARGV.fetch(1)) if $PROGRAM_NAME == __FILE__
