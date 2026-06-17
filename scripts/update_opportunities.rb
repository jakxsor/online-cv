#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'

ROOT = File.expand_path('..', __dir__)

SOURCE_URLS = {
  arbeitnow: 'https://www.arbeitnow.com/api/job-board-api',
  remoteok: 'https://remoteok.com/api',
  themuse_science: 'https://www.themuse.com/api/public/jobs?category=Science%20and%20Engineering&page=1'
}.freeze

KEYWORDS = {
  'life cycle assessment' => 28,
  'safe and sustainable' => 28,
  'sustainability' => 18,
  'environmental' => 16,
  'chemical' => 15,
  'pharma' => 15,
  'pharmaceutical' => 15,
  'risk assessment' => 14,
  'occupational exposure' => 14,
  'policy' => 13,
  'foresight' => 13,
  'research' => 11,
  'scientist' => 11,
  'r&d' => 10,
  'climate' => 10,
  'nanomedicine' => 10,
  'process engineer' => 9,
  'product development' => 9
}.freeze

NOISE = %w[
  sales marketing frontend backend fullstack full-stack devops accountant payroll nurse
  restaurant retail driver finance banker security designer social-media
].freeze

def fetch_json(url)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'jacopo-sorani-opportunity-scout/1.0'
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 25) do |http|
    http.request(request)
  end
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError => e
  warn "Fetch failed for #{url}: #{e.message}"
  nil
end

def strip_html(value)
  value.to_s.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
end

def country_scope(location)
  text = location.to_s.downcase
  scope = []
  scope << 'remote' if text.match?(/remote|worldwide|europe/)
  scope << 'eu' if text.match?(/brussels|belgium|europe|european/)
  scope << 'ch' if text.match?(/switzerland|zurich|basel|lausanne|st\. gallen/)
  scope << 'it' if text.match?(/italy|milan|rome|bologna|florence/)
  scope << 'de' if text.match?(/germany|berlin|munich|hamburg|d.seldorf|dusseldorf|duesseldorf|aachen|cuxhaven/)
  scope << 'nl' if text.match?(/netherlands|amsterdam|rotterdam|utrecht/)
  scope << 'fr' if text.match?(/france|paris|lyon/)
  scope << 'dk' if text.match?(/denmark|copenhagen/)
  scope << 'se' if text.match?(/sweden|stockholm|gothenburg/)
  scope << 'uk' if text.match?(/united kingdom|london|cambridge|oxford|uk/)
  scope = ['remote'] if scope.empty? && text.empty?
  scope.uniq
end

def infer_types(text)
  value = text.downcase
  types = []
  types << 'pharma' if value.match?(/pharma|pharmaceutical|biotech|medtech|medical device|pharmacology/)
  types << 'chemicals' if value.match?(/chemical|materials|reach|product stewardship/)
  types << 'consulting' if value.match?(/consultant|consulting|advisory/)
  types << 'policy' if value.match?(/policy|regulatory|agency|commission|foresight/)
  types << 'academic' if value.match?(/postdoc|phd|university|professor/)
  types << 'research' if value.match?(/research|scientist|r&d|laboratory/)
  types << 'impact' if value.match?(/climate|sustainability|environmental|circular/)
  types << 'industry' if types.empty? || value.match?(/engineer|product|operations|industry/)
  types.uniq
end

def score_offer(title, org, description)
  title_text = title.to_s.downcase
  full_text = [title, org, description].join(' ').downcase
  score = 0

  KEYWORDS.each do |term, weight|
    score += weight if full_text.include?(term)
    score += (weight / 2) if title_text.include?(term)
  end

  NOISE.each { |term| score -= 18 if title_text.include?(term) }
  score
end

def normalize_arbeitnow(job)
  title = strip_html(job['title'])
  org = strip_html(job['company_name'])
  location = strip_html(job['location'])
  description = strip_html(job['description'])
  score = score_offer(title, org, description)
  return nil if score < 18

  text = [title, org, description].join(' ')
  {
    title: title,
    org: org,
    country: location.empty? ? 'Europe' : location,
    scope: country_scope(location),
    type: infer_types(text).first,
    types: infer_types(text),
    url: job['url'],
    source: 'Arbeitnow',
    notes: description[0, 260],
    deadline: '',
    discoveredAt: Time.at(job['created_at'].to_i).utc.iso8601,
    sourceScore: score
  }
end

def normalize_remoteok(job)
  return nil unless job.is_a?(Hash)

  title = strip_html(job['position'])
  org = strip_html(job['company'])
  location = strip_html(job['location'])
  description = strip_html(job['description'])
  score = score_offer(title, org, description)
  return nil if score < 30

  text = [title, org, description, Array(job['tags']).join(' ')].join(' ')
  {
    title: title,
    org: org,
    country: location.empty? ? 'Remote' : location,
    scope: (country_scope(location) + ['remote']).uniq,
    type: infer_types(text).first,
    types: infer_types(text),
    url: job['url'],
    source: 'RemoteOK',
    notes: description[0, 260],
    deadline: '',
    discoveredAt: Time.now.utc.iso8601,
    sourceScore: score
  }
end

def normalize_themuse(job)
  title = strip_html(job['name'])
  org = strip_html(job.dig('company', 'name'))
  location = Array(job['locations']).map { |item| item['name'] }.compact.join(', ')
  description = strip_html(job['contents'])
  score = score_offer(title, org, description)
  return nil if score < 20

  text = [title, org, description].join(' ')
  {
    title: title,
    org: org,
    country: location.empty? ? 'Unknown' : location,
    scope: country_scope(location),
    type: infer_types(text).first,
    types: infer_types(text),
    url: job.dig('refs', 'landing_page'),
    source: 'The Muse',
    notes: description[0, 260],
    deadline: '',
    discoveredAt: Time.now.utc.iso8601,
    sourceScore: score
  }
end

offers = []

if (data = fetch_json(SOURCE_URLS[:arbeitnow]))
  offers.concat(Array(data['data']).map { |job| normalize_arbeitnow(job) }.compact)
end

if (data = fetch_json(SOURCE_URLS[:remoteok]))
  offers.concat(Array(data).map { |job| normalize_remoteok(job) }.compact)
end

if (data = fetch_json(SOURCE_URLS[:themuse_science]))
  offers.concat(Array(data['results']).map { |job| normalize_themuse(job) }.compact)
end

offers = offers
  .select { |item| item[:url].to_s.start_with?('http') }
  .uniq { |item| [item[:title].downcase, item[:org].downcase] }
  .sort_by { |item| -item[:sourceScore].to_i }
  .first(40)

payload = {
  generatedAt: Time.now.utc.iso8601,
  sourceNote: 'Generated from public job feeds. The static site filters these direct openings locally by country, type and CV domains.',
  opportunities: offers
}

File.write(File.join(ROOT, 'opportunities.json'), JSON.pretty_generate(payload) + "\n")
puts "Wrote #{offers.length} direct opportunities"
