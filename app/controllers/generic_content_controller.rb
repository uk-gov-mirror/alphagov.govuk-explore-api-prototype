require "httparty"

class GenericContentController < ApplicationController
  def show
    url = "https://www.gov.uk/api/content/#{params[:slug]}"
    content_item = http_get(url).parsed_response
    details = content_item.dig("details", "body")
    priority_taxons = [
      "634fd193-8039-4a70-a059-919c34ff4bfc",
      "614b2e65-56ac-4f8d-bb9c-d1a14167ba25",
      "d6c2de5d-ef90-45d1-82d4-5f2438369eea",
      "272308f4-05c8-4d0d-abc7-b7c2e3ccd249",
      "b7f57213-4b16-446d-8ded-81955d782680",
      "65666cdf-b177-4d79-9687-b9c32805e450",
    ]
    taxons = content_item.dig("links", "taxons")
    part_of_taxons = taxons && taxons.select do |taxon|
      priority_taxons.include?(taxon["content_id"])
    end
    is_html_pub = params[:htmlpub] == "true"

    if !details && content_item.dig("details", "parts")
      details = format_parts(content_item.dig("details", "parts"), content_item["base_path"], params[:slug])
    end

    payload = {
      title: content_item["title"],
      contents_list: content_item.dig("details", "parts") ? contents_list_from_parts(content_item.dig("details", "parts"), content_item["base_path"], params[:slug]) : contents_list_from_headings_with_ids(details),
      is_consultation: content_item["schema_name"] == "consultation",
      opening_date_time: content_item.dig("details", "opening_date"),
      opening_date_time_display: display_date_and_time(content_item.dig("details", "opening_date")),
      closing_date_time: content_item.dig("details", "closing_date"),
      closing_date_time_display: display_date_and_time(content_item.dig("details", "closing_date"), rollback_midnight: true),
      intro: content_item.dig("details", "introduction"),
      details: strip_govuk_links(details),
      documents: content_item.dig("details", "documents"),
      show_form: content_item["schema_name"] == "local_transaction",
      need_to_know: content_item.dig("details", "need_to_know"),
      breadcrumbs: breadcrumb_content(content_item, is_html_pub).reverse,
      part_of_taxon: part_of_taxons && part_of_taxons[0],
      context: context_phrases[content_item["document_type"]],
      description: content_item["description"],
      metadata: {
        from: content_item.dig("links", "organisations"),
        first_published: display_date(content_item["details"]["first_public_at"] || content_item["first_published_at"]),
        last_updated: any_updates?(content_item) && display_date(content_item["public_updated_at"]),
      },
      history: history(content_item),
      topic: content_item.dig("links", "topics", 0),
      related_content: format_related_content((content_item.dig("links", "ordered_related_items") || content_item.dig("links", "suggested_ordered_related_items")), 3, false, content_item.dig("links", "related_guides")),
      step_by_step: format_related_content(content_item.dig("links", "part_of_step_navs"), false, true),
      topical_events: format_related_content(content_item.dig("links", "topical_events")),
      collections: format_related_content(content_item.dig("links", "document_collections")),
      topics: format_related_content(content_item.dig("links", "topics"), false, true),
    }

    if is_html_pub
      payload[:part_of_parent] = content_item.dig("links", "parent", 0)
      payload[:context] = context_phrases[payload[:part_of_parent]["document_type"]]
    end

    if content_item["schema_name"] == "document_collection"
      payload[:document_collections] = format_collection_documents(content_item.dig("links", "documents"), content_item.dig("details", "collection_groups"))
    end

    if content_item["schema_name"] == "guide"
      payload[:is_mainstream_guide] = true
    end

    render json: payload
  end

private
  def http_get(url)
    HTTParty.get(url, follow_redirects: true)
  end

  def breadcrumb_content(content_item, is_html_pub = false)
    return [] if !content_item

    if is_html_pub
      parent_content_item = http_get("https://www.gov.uk#{content_item.dig("links", "parent", 0, "api_path")}").parsed_response
      breadcrumb_content(parent_content_item)
    else
      if content_item.dig("links", "parent")
        breadcrumbs_by_parent(content_item.dig("links", "parent", 0))
      elsif content_item.dig("links", "topics")
        content_item.dig("links", "topics")
      else
        []
      end
    end
  end

  def breadcrumbs_by_parent(parent)
    breadcrumbs = [parent]
    potential_parent = parent.dig("links", "parent", 0)

    if potential_parent
      (breadcrumbs << breadcrumbs_by_parent(potential_parent)).flatten!
    else
      breadcrumbs
    end
  end

  def display_date(timestamp)
    I18n.l(Time.zone.parse(timestamp), format: "%-d %B %Y", locale: "en")
  end

  def display_date_and_time(timestamp, rollback_midnight: false)
    return false unless timestamp.present?

    time = Time.zone.parse(timestamp)
    date_format = "%-e %B %Y"
    time_format = "%l:%M%P"

    if rollback_midnight && (time.strftime(time_format) == "12:00am")
      # 12am, 12:00am and "midnight on" can all be misinterpreted
      # Use 11:59pm on the day before to remove ambiguity
      # 12am on 10 January becomes 11:59pm on 9 January
      time -= 1.second
    end
    I18n.l(time, format: "#{time_format} on #{date_format}").gsub(":00", "").gsub("12pm", "midday").gsub("12am on ", "").strip
  end

  def any_updates?(content_item)
    if content_item["public_updated_at"] && content_item["first_published_at"]
      Time.zone.parse(content_item["public_updated_at"]) != Time.zone.parse(content_item["first_published_at"])
    else
      false
    end
  end

  def contents_list_from_headings_with_ids(content)
    if (content.kind_of?(Array))
      content.map do |part|
        {
          text: part["title"],
          id: part["slug"],
        }
      end
    else
      headings = Nokogiri::HTML(content).css("h2").map do |heading|
        id = heading.attribute("id")
        { text: heading.text.gsub(/:$/, ""), id: id.value } if id
      end
      headings.compact
    end
  end

  def contents_list_from_parts(parts, base_path, slug)
    parts.each_with_index.map do |part, i|
      contents_list_item = {
        text: part["title"],
      }

      is_active_page = (part["slug"] == slug || (base_path == slug && i == 0))

      contents_list_item[:slug] = is_active_page ? false : "#{base_path}/#{part["slug"]}"
      contents_list_item[:is_current_page] = is_active_page

      contents_list_item
    end
  end

  def history(content_item)
    return [] unless any_updates?(content_item)

    change_history(content_item).sort_by {|item| Time.zone.parse(item[:timestamp])}.reverse
  end

  def change_history(content_item)
    changes = content_item["details"]["change_history"] || []
    changes.map do |item|
      {
        display_time: display_date(item["public_timestamp"]),
        note: item["note"],
        timestamp: item["public_timestamp"],
      }
    end
  end

  def context_phrases
    {
      "aaib_report" => "Air Accidents Investigation Branch report",
      "announcement" => "Announcement",
      "asylum_support_decision" => "Asylum support tribunal decision",
      "authored_article" => "Authored article",
      "business_finance_support_scheme" => "Business finance support scheme",
      "case_study" => "Case study",
      "closed_consultation" => "Closed consultation",
      "cma_case" => "Competition and Markets Authority case",
      "coming_soon" => "Coming Soon",
      "consultation" => "Consultation",
      "consultation_outcome" => "Consultation outcome",
      "corporate_information_page" => "Information page",
      "corporate_report" => "Corporate report",
      "correspondence" => "Correspondence",
      "countryside_stewardship_grant" => "Countryside Stewardship grant",
      "decision" => "Decision",
      "detailed_guide" => "Guidance",
      "dfid_research_output" => "Research for Development Output",
      "document_collection" => "Collection",
      "draft_text" => "Draft text",
      "drug_safety_update" => "Drug Safety Update",
      "employment_appeal_tribunal_decision" => "Employment appeal tribunal decision",
      "employment_tribunal_decision" => "Employment tribunal decision",
      "esi_fund" => "European Structural and Investment Fund (ESIF)",
      "fatality_notice" => "Fatality notice",
      "foi_release" => "FOI release",
      "form" => "Form",
      "government_response" => "Government response",
      "guidance" => "Guidance",
      "impact_assessment" => "Impact assessment",
      "imported" => "imported - awaiting type",
      "independent_report" => "Independent report",
      "international_development_fund" => "International development funding",
      "international_treaty" => "International treaty",
      "maib_report" => "Marine Accident Investigation Branch report",
      "map" => "Map",
      "medical_safety_alert" => "Alerts and recalls for drugs and medical devices",
      "national" => "National statistics announcement",
      "national_statistics" => "National Statistics",
      "national_statistics_announcement" => "National statistics announcement",
      "news_article" => "News article",
      "news_story" => "News story",
      "notice" => "Notice",
      "official" => "Official statistics announcement",
      "official_statistics" => "Official Statistics",
      "official_statistics_announcement" => "Official statistics announcement",
      "open_consultation" => "Open consultation",
      "oral_statement" => "Oral statement to Parliament",
      "policy" => "Policy",
      "policy_paper" => "Policy paper",
      "press_release" => "Press release",
      "promotional" => "Promotional material",
      "publication" => "Publication",
      "raib_report" => "Rail Accident Investigation Branch report",
      "regulation" => "Regulation",
      "research" => "Research and analysis",
      "residential_property_tribunal_decision" => "Residential property tribunal decision",
      "service_sign_in" => "Service sign in",
      "service_standard_report" => "Service Standard Report",
      "speaking_notes" => "Speaking notes",
      "speech" => "Speech",
      "standard" => "Standard",
      "statement_to_parliament" => "Statement to Parliament",
      "statistical_data_set" => "Statistical data set",
      "statistics_announcement" => "Statistics release announcement",
      "statutory_guidance" => "Statutory guidance",
      "take_part" => "Take part",
      "tax_tribunal_decision" => "Tax and Chancery tribunal decision",
      "transcript" => "Transcript",
      "transparency" => "Transparency data",
      "utaac_decision" => "Administrative appeals tribunal decision",
      "world_location_news_article" => "News article",
      "world_news_story" => "World news story",
      "written_statement" => "Written statement to Parliament",
    }
  end

  def format_collection_documents(documents, groupings)
    return [] unless documents.present? && groupings.present?

    filtered_groups = []

    groupings.each do |group|
      unless group["documents"].empty?
        filtered_group = {
          title: group["title"],
          slug: group["title"].gsub(" ", "-").downcase,
          body: group["body"],
        }

        filtered_documents = []

        group["documents"].each do |doc_id|
          selected_doc = documents.filter do |document|
            document["content_id"] == doc_id
          end

          if selected_doc.present?
            selected_doc = selected_doc[0]
            selected_doc["formatted_date"] = display_date(selected_doc["public_updated_at"])
            selected_doc["attribute"] = context_phrases[selected_doc["document_type"]]

            filtered_documents << selected_doc
          end
        end

        filtered_group[:documents] = filtered_documents

        unless filtered_documents.empty?
          filtered_groups << filtered_group
        end
      end
    end

    filtered_groups
  end

  def format_parts(parts, base_path, slug)
    stripped_slug = slug.gsub(base_path, "").gsub("/", "")
    filter = stripped_slug.empty? ? parts[0]["slug"]: stripped_slug
    correct_part = parts.filter do |part|
      part["slug"] == filter
    end

    correct_part.map do |part|
      part["slug"] = "#{base_path}/#{part["slug"]}"
      part
    end
  end

  def format_related_content(related, limit = false, alphabetise = false, combined_with = false)
    return [] unless related && related.kind_of?(Array)

    formatted = related

    if limit
      formatted = formatted.take(limit)
    end

    if alphabetise
      formatted = formatted.sort do |a, b|
        a["title"] <=> b["title"]
      end
    end

    if combined_with && combined_with.kind_of?(Array)
      formatted = formatted.concat(combined_with)
    end

    formatted
  end

  def strip_govuk_links(details)
    if details.kind_of?(Array)
      details.map do |item|
        item["body"] = strip_govuk_links(item["body"])
        item
      end
    else
      details.gsub(/(https?:\/\/(www\.)?gov\.uk(\/)?)/, "/")
    end
  end
end
