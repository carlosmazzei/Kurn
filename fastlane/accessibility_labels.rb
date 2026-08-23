require "json"

class AccessibilityLabels
  DEVICE_FAMILIES = %w[IPHONE IPAD APPLE_WATCH].freeze
  SUPPORT_KEYS = %w[
    supportsAudioDescriptions
    supportsCaptions
    supportsDarkInterface
    supportsDifferentiateWithoutColorAlone
    supportsLargerText
    supportsReducedMotion
    supportsSufficientContrast
    supportsVoiceControl
    supportsVoiceover
  ].freeze

  def self.load(path)
    config = JSON.parse(File.read(path))
    url = config.fetch("accessibilityUrl")
    declarations = config.fetch("declarations")
    raise "accessibilityUrl must use HTTPS" unless url.start_with?("https://")
    raise "declarations must contain #{DEVICE_FAMILIES.join(', ')}" unless declarations.keys.sort == DEVICE_FAMILIES.sort

    declarations.each do |device_family, attributes|
      raise "Invalid attributes for #{device_family}" unless attributes.keys.sort == SUPPORT_KEYS.sort
      raise "All attributes for #{device_family} must be boolean" unless attributes.values.all? { |value| value == true || value == false }
    end

    config
  end

  def initialize(client:, app_id:, config:)
    @client = client
    @app_id = app_id
    @config = config
  end

  def sync(publish: false)
    actions = []
    actions << sync_url
    existing = declarations

    @config.fetch("declarations").each do |device_family, support|
      declaration = preferred(existing, device_family)
      declaration, action = upsert(device_family, support, declaration)
      actions << action
      actions << publish_declaration(declaration) if publish && declaration.dig("attributes", "state") != "PUBLISHED"
    end

    actions.compact
  end

  private

  def sync_url
    response = @client.get("v1/apps/#{@app_id}")
    current = response.body.dig("data", "attributes", "accessibilityUrl")
    desired = @config.fetch("accessibilityUrl")
    return "Accessibility URL unchanged" if current == desired

    @client.patch(
      "v1/apps/#{@app_id}",
      {
        data: {
          type: "apps",
          id: @app_id,
          attributes: { accessibilityUrl: desired }
        }
      }
    )
    "Updated accessibility URL"
  end

  def declarations
    responses = @client.get(
      "v1/apps/#{@app_id}/accessibilityDeclarations",
      { limit: 200 }
    ).all_pages
    responses.flat_map { |response| response.body.fetch("data", []) }
  end

  def preferred(existing, device_family)
    matches = existing.select { |item| item.dig("attributes", "deviceFamily") == device_family }
    matches.find { |item| item.dig("attributes", "state") == "DRAFT" } ||
      matches.find { |item| item.dig("attributes", "state") == "PUBLISHED" }
  end

  def upsert(device_family, support, declaration)
    if declaration.nil?
      response = @client.post(
        "v1/accessibilityDeclarations",
        {
          data: {
            type: "accessibilityDeclarations",
            attributes: support.merge("deviceFamily" => device_family),
            relationships: {
              app: { data: { type: "apps", id: @app_id } }
            }
          }
        }
      )
      return [response.body.fetch("data"), "Created #{device_family} accessibility draft"]
    end

    current = declaration.fetch("attributes").slice(*SUPPORT_KEYS)
    return [declaration, "#{device_family} accessibility declaration unchanged"] if current == support

    response = @client.patch(
      "v1/accessibilityDeclarations/#{declaration.fetch('id')}",
      {
        data: {
          type: "accessibilityDeclarations",
          id: declaration.fetch("id"),
          attributes: support
        }
      }
    )
    [response.body.fetch("data"), "Updated #{device_family} accessibility draft"]
  end

  def publish_declaration(declaration)
    device_family = declaration.dig("attributes", "deviceFamily")
    @client.patch(
      "v1/accessibilityDeclarations/#{declaration.fetch('id')}",
      {
        data: {
          type: "accessibilityDeclarations",
          id: declaration.fetch("id"),
          attributes: { publish: true }
        }
      }
    )
    "Published #{device_family} accessibility declaration"
  end
end
