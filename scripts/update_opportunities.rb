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

JOBICY_TAGS = %w[
  sustainability climate environmental research scientist pharma pharmaceutical
  chemistry chemical policy healthcare medical data operations project
].freeze

KEYWORDS = {
  'life cycle assessment' => 28,
  'lca' => 26,
  'ssbd' => 26,
  'safe and sustainable' => 28,
  'product sustainability' => 24,
  'carbon footprint' => 22,
  'environmental footprint' => 22,
  'circular economy' => 20,
  'sustainability' => 18,
  'environmental' => 16,
  'chemical' => 15,
  'chemistry' => 15,
  'pharma' => 15,
  'pharmaceutical' => 15,
  'medical device' => 15,
  'clinical research' => 14,
  'risk assessment' => 14,
  'toxicology' => 14,
  'ecotoxicology' => 14,
  'occupational exposure' => 14,
  'ehs' => 14,
  'reach' => 14,
  'regulatory' => 13,
  'policy' => 13,
  'foresight' => 13,
  'research' => 11,
  'scientist' => 11,
  'r&d' => 10,
  'climate' => 10,
  'nanomedicine' => 10,
  'process engineer' => 9,
  'product development' => 9,
  'project manager' => 7,
  'data analyst' => 7
}.freeze

NOISE = %w[
  sales marketing frontend backend fullstack full-stack devops accountant payroll nurse
  restaurant retail driver finance banker security designer social-media claims support
  customer-success supply-chain devsecops
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

def fetch_jobicy(tag)
  url = "https://jobicy.com/api/v2/remote-jobs?count=100&geo=europe&tag=#{URI.encode_www_form_component(tag)}"
  fetch_json(url)
end

def strip_html(value)
  value.to_s.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
end

def infer_language(title, description, explicit = nil)
  value = explicit.to_s.downcase.strip
  return value if %w[en it de fr nl].include?(value)

  text = [title, description].join(' ').downcase
  return 'de' if text.match?(/\b(m\/w\/d|w\/m\/d|aufgaben|dein|ihre|wir suchen|kenntnisse|berufserfahrung|du bist)\b/)
  return 'it' if text.match?(/\b(cerchiamo|mansioni|requisiti|laurea|candidato|azienda|sostenibilita|chimica)\b/)
  return 'fr' if text.match?(/\b(nous recherchons|vous serez|candidat|developpement durable|environnement)\b/)
  return 'nl' if text.match?(/\b(wij zoeken|functie|duurzaamheid|milieu|onderzoek|ervaring)\b/)
  'en'
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
  scope << 'eu' if (scope & %w[it de nl fr dk se]).any?
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

  NOISE.each { |term| score -= 30 if title_text.include?(term) }
  score += 10 if title_text.match?(/scientist|research|engineer|analyst|consultant|manager/)
  score += 8 if full_text.match?(/europe|remote|hybrid|switzerland|germany|italy|brussels/)
  score
end

def base_offer(title:, org:, country:, scope:, type:, types:, url:, source:, notes:, discovered_at:, source_score:, language:)
  {
    title: title,
    org: org,
    country: country,
    scope: scope,
    type: type,
    types: types,
    url: url,
    source: source,
    notes: notes,
    deadline: '',
    language: language,
    discoveredAt: discovered_at,
    sourceScore: source_score
  }
end

def normalize_arbeitnow(job)
  title = strip_html(job['title'])
  org = strip_html(job['company_name'])
  location = strip_html(job['location'])
  description = strip_html(job['description'])
  score = score_offer(title, org, description)
  return nil if score < 10

  text = [title, org, description].join(' ')
  types = infer_types(text)
  base_offer(
    title: title,
    org: org,
    country: location.empty? ? 'Europe' : location,
    scope: country_scope(location),
    type: types.first,
    types: types,
    url: job['url'],
    source: 'Arbeitnow',
    notes: description[0, 260],
    discovered_at: Time.at(job['created_at'].to_i).utc.iso8601,
    source_score: score,
    language: infer_language(title, description)
  )
end

def normalize_remoteok(job)
  return nil unless job.is_a?(Hash)

  title = strip_html(job['position'])
  org = strip_html(job['company'])
  location = strip_html(job['location'])
  description = strip_html(job['description'])
  score = score_offer(title, org, description)
  return nil if score < 18

  text = [title, org, description, Array(job['tags']).join(' ')].join(' ')
  types = infer_types(text)
  scope = country_scope(location)
  scope = (scope + ['remote']).uniq if location.empty? || location.downcase.match?(/remote|worldwide|europe|emea|anywhere/)
  return nil if scope.empty?

  base_offer(
    title: title,
    org: org,
    country: location.empty? ? 'Remote' : location,
    scope: scope,
    type: types.first,
    types: types,
    url: job['url'],
    source: 'RemoteOK',
    notes: description[0, 260],
    discovered_at: Time.now.utc.iso8601,
    source_score: score,
    language: infer_language(title, description)
  )
end

def normalize_themuse(job)
  title = strip_html(job['name'])
  org = strip_html(job.dig('company', 'name'))
  location = Array(job['locations']).map { |item| item['name'] }.compact.join(', ')
  description = strip_html(job['contents'])
  score = score_offer(title, org, description)
  return nil if score < 12

  text = [title, org, description].join(' ')
  types = infer_types(text)
  base_offer(
    title: title,
    org: org,
    country: location.empty? ? 'Unknown' : location,
    scope: country_scope(location),
    type: types.first,
    types: types,
    url: job.dig('refs', 'landing_page'),
    source: 'The Muse',
    notes: description[0, 260],
    discovered_at: Time.now.utc.iso8601,
    source_score: score,
    language: infer_language(title, description)
  )
end

def normalize_jobicy(job)
  title = strip_html(job['jobTitle'])
  org = strip_html(job['companyName'])
  location = strip_html(job['jobGeo'])
  description = strip_html(job['jobDescription'] || job['jobExcerpt'])
  score = score_offer(title, org, description)
  return nil if score < 12

  text = [title, org, description, job['jobIndustry']].join(' ')
  types = infer_types(text)
  scope = (country_scope(location) + ['remote']).uniq
  base_offer(
    title: title,
    org: org,
    country: location.empty? ? 'Remote Europe' : location,
    scope: scope,
    type: types.first,
    types: types,
    url: job['url'],
    source: 'Jobicy',
    notes: description[0, 260],
    discovered_at: begin
      Time.parse(job['pubDate'].to_s).utc.iso8601
    rescue StandardError
      Time.now.utc.iso8601
    end,
    source_score: score,
    language: infer_language(title, description)
  )
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

JOBICY_TAGS.each do |tag|
  data = fetch_jobicy(tag)
  offers.concat(Array(data && data['jobs']).map { |job| normalize_jobicy(job) }.compact)
end

offers = offers
  .select { |item| item[:url].to_s.start_with?('http') }
  .select { |item| item[:scope].any? }
  .uniq { |item| [item[:title].downcase, item[:org].downcase] }
  .sort_by { |item| -item[:sourceScore].to_i }
  .first(120)

payload = {
  generatedAt: Time.now.utc.iso8601,
  sourceNote: 'Generated from public job feeds. The static site filters these direct openings locally by country, type and CV domains.',
  opportunities: offers
}

File.write(File.join(ROOT, 'opportunities.json'), JSON.pretty_generate(payload) + "\n")
puts "Wrote #{offers.length} direct opportunities"
