require "httparty"
require "taxonomies"

class BrowseController < ApplicationController
  def show_mainstream_topic
    topic(params[:topic_slug], :mainstream)
  end

  def show_mainstream_subtopic
    subtopic(params[:topic_slug], params[:subtopic_slug], :mainstream)
  end

  def show_specialist_topic
    topic(params[:topic_slug], :specialist)
  end

  def show_specialist_subtopic
    subtopic(params[:topic_slug], params[:subtopic_slug], :specialist)
  end

  def show_topics
    url = "https://www.gov.uk/api/content/browse"
    content_item = http_get(url).parsed_response
    subtopics = content_item["links"]["top_level_browse_pages"].sort_by { |k| k["title"] }
    payload = {
      title: content_item["title"],
      subtopics: subtopics.map do |subtopic|
        {
          title: subtopic["title"],
          link: subtopic["base_path"],
          description: subtopic["description"],
        }
      end,
    }
    render json: payload
  end

  def show_generic_content
    url = "https://www.gov.uk/api/content/#{params[:slug]}"
    content_item = http_get(url).parsed_response
    details = content_item.dig("details", "body") || format_parts(content_item.dig("details", "parts"), content_item["base_path"], params[:slug])
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
    collection_documents = content_item["document_type"] == "document_collection" && format_collection_documents(content_item.dig("links", "documents"))

    payload = {
      title: content_item["title"],
      contents_list: content_item.dig("details", "parts") ? contents_list_from_parts(content_item.dig("details", "parts"), content_item["base_path"], params[:slug]) : contents_list_from_headings_with_ids(details),
      is_consultation: content_item["schema_name"] == "consultation",
      opening_date_time: content_item.dig("details", "opening_date"),
      opening_date_time_display: display_date_and_time(content_item.dig("details", "opening_date")),
      closing_date_time: content_item.dig("details", "closing_date"),
      closing_date_time_display: display_date_and_time(content_item.dig("details", "closing_date"), rollback_midnight: true),
      intro: content_item.dig("details", "introduction"),
      details: details,
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

    if collection_documents
      payload[:main_document] = collection_documents[0]
      payload[:archived_documents] = collection_documents.drop(1)
    end

    if content_item["document_type"] == "guide"
      payload[:is_mainstream_guide] = true
    end

    render json: payload
  end

private

  def topic(topic_slug, topic_type)
    if topic_type == :mainstream
      url = "https://www.gov.uk/api/content/browse/#{topic_slug}"
      content_item = http_get(url).parsed_response
      subtopic_order = content_item["details"]["ordered_second_level_browse_pages"]
      subtopics = content_item["links"]["second_level_browse_pages"]

      taxon_search_filter = (Taxonomies.taxon_filter_lookup("/browse/#{topic_slug}") || "")
      subs = subtopic_order.map { |content_id|
        subtopic = subtopics.detect { |s| s["content_id"] == content_id }
        next if subtopic.nil?

        {
          title: subtopic["title"],
          link: subtopic["base_path"],
        }
      }.compact
    else
      url = "https://www.gov.uk/api/content/topic/#{topic_slug}"
      content_item = http_get(url).parsed_response
      subtopics = content_item["links"]["children"]
      taxon_search_filter = (Taxonomies.taxon_filter_lookup("/topic/#{topic_slug}") || "")
      subs = subtopics.map { |sub| { title: sub["title"], link: sub["base_path"] } }
    end

    # TODO: This is hard coded for now. Refactor if we have more than a couple.
    if topic_slug == "visas-immigration"
      subs << {
        title: "Visas and immigration operational guidance",
        link: "/browse/visas-immigration/immigration-operational-guidance",
      }
    end

    payload = {
      title: content_item["title"],
      description: content_item["description"],
      subtopics: subs,
    }

    if taxon_search_filter != ""
      payload[:taxon_search_filter] = taxon_search_filter
      payload[:latest_news] = latest_news_content(topic_type).map do |news_result|
        {
          title: news_result["title"],
          description: news_result["description"],
          url: news_result["_id"],
          topic: news_result["content_purpose_supergroup"],
          subtopic: news_result["content_purpose_subgroup"],
          image_url: news_result["image_url"] || "https://assets.publishing.service.gov.uk/media/5e59279b86650c53b2cefbfe/placeholder.jpg",
          public_timestamp: news_result["public_timestamp"],
        }
      end
      payload[:organisations] = topic_organisations(topic_type)
      payload[:featured] = most_popular_content(subtopics, topic_type)
    end

    render json: payload
  end

  def subtopic(topic_slug, subtopic_slug, topic_type)
    topic_prefix = topic_type == :mainstream ? "browse" : "topic"

    url = "https://www.gov.uk/api/content/#{topic_prefix}/#{topic_slug}/#{subtopic_slug}"
    puts "fetching #{url}"
    content_item = http_get(url).parsed_response

    visas_topic = load_fake_sub_topics.first


    sub_topic = visas_topic.specialist_topics.find_all{ |sub| sub.key == subtopic_slug }
    sub_topic = sub_topic.empty? ? nil : sub_topic.first

    payload = if sub_topic
                {
                  title: sub_topic.title,
                  description: sub_topic.description,
                  parent:
                    {
                      link: visas_topic.link,
                      title: visas_topic.title,
                    },
                }
              else
                {
                  title: content_item["title"],
                  description: content_item["description"],
                  parent:
                    {
                      link: content_item["links"]["parent"][0]["base_path"],
                      title: content_item["links"]["parent"][0]["title"],
                    },
                }
              end

    payload["subtopic_sections"] = if sub_topic
                                     {
                                       items: fake_accordion_content(sub_topic),
                                     }
                                   else
                                     # TODO: hard coding in as a way to "fake routes" to the page for testing
                                     items = accordion_content(content_item, topic_type)
                                     if topic_slug == "visas-immigration" && subtopic_slug != "arriving-in-the-uk"
                                       items << {
                                         heading: { text: "Visas and immigration operational guidance" },
                                         content: {
                                           html: "<ul class='govuk-list'><li><a href='/browse/visas-immigration/immigration-operational-guidance'>Visas and immigration operational guidance</a></li></ul>",
                                         },
                                       }
                                     end

                                     if topic_slug == "citizenship" && subtopic_slug == "citizenship"
                                       items = items.map do |item|
                                         if item.dig(:heading, :text) == "Forms and guidance"
                                           markup = item.dig(:content, :html)
                                           item[:content][:html] = markup.gsub("</ul>", "<li><a href='/browse/visas-immigration/immigration-operational-guidance'>Visas and immigration operational guidance</a></li></ul>")
                                         end

                                         item
                                       end
                                     end

                                     {
                                       items: items,
                                     }
                                   end

    taxon_search_filter = (Taxonomies.taxon_filter_lookup("/#{topic_prefix}/#{topic_slug}/#{subtopic_slug}") || "")
    if taxon_search_filter != ""
      payload[:taxon_search_filter] = taxon_search_filter
      payload[:latest_news] = latest_news_content(topic_type).map do |news_result|
        {
          title: news_result["title"],
          description: news_result["description"],
          url: news_result["_id"],
          topic: news_result["content_purpose_supergroup"],
          subtopic: news_result["content_purpose_subgroup"],
          image_url: news_result["image_url"] || "https://assets.publishing.service.gov.uk/media/5e59279b86650c53b2cefbfe/placeholder.jpg",
          public_timestamp: news_result["public_timestamp"],
        }
      end
      payload[:organisations] = topic_organisations(topic_type)
      payload[:related_topics] = related_topics(content_item)
    end

    render json: payload
  end

  def load_fake_sub_topics
    topics ||= Topic.load_all
    topics
  end

  def related_topics(subtopic_details)
    (subtopic_details["links"]["second_level_browse_pages"] || []).map do |topic|
      { title: topic["title"], link: topic["base_path"] }
    end
  end

  def topic_filter(topic_path, topic_type)
    taxon_id = Taxonomies.content_id(topic_path, topic_type)
    if taxon_id.present?
      { filter_part_of_taxonomy_tree: taxon_id }
    else
      {}
    end
  end

  def accordion_content(subtopic_details, topic_type)
    groups = if subtopic_details["details"] && subtopic_details["details"]["groups"]
               subtopic_details["details"]["groups"].any? ? subtopic_details["details"]["groups"] : default_group
             else
               []
             end

    items_from_search = accordion_items_from_search(subtopic_details, topic_type)

    groups.map { |detail|
      list = if subtopic_details["details"]["groups"].nil? || subtopic_details["details"]["groups"].empty?
               search_accordion_list_items(items_from_search)
             elsif subtopic_details["details"]["second_level_ordering"] == "alphabetical" || detail["contents"].nil?
               alphabetical_accordion_list_items(subtopic_details["links"]["children"])
             else
               curated_accordion_list_items(detail["contents"], items_from_search)
             end

      next if list.empty?

      {
        heading: { text: detail["name"] || "A to Z" },
        content: { html: "<ul class='govuk-list'>#{list}</ul>" },
      }
    }.compact
  end

  def fake_accordion_content(specialist_topic)
    specialist_topic.sections.map do |section|
      {
        heading: { text: section.label },
        content: {
          html: "<ul class='govuk-list'>#{fake_accordion_links(section)}</ul>",
        },
      }
    end
  end

  def fake_accordion_links(section)
    section.section_links.map { |link| "<li><a href='#{link.link}'>#{link.text}</a></li>" }.join
  end

  def default_group
    [{ name: "A to Z" }]
  end

  def alphabetical_accordion_list_items(tagged_children)
    tagged_children.sort_by { |child| child["title"] }.map { |child|
      "<li><a href='#{child['base_path']}'>#{child['title']}</a></li>"
    }.join
  end

  def curated_accordion_list_items(ordered_paths, items_from_search)
    tagged_children_paths = items_from_search.map { |child| child[:link] }

    ordered_paths
      .select { |path| tagged_children_paths.include? path }
      .map { |path|
        current_item = items_from_search.detect { |child| child[:link] == path }
        "<li><a href='#{path}'>#{current_item[:title]}</a></li>"
      }.join
  end

  def search_accordion_list_items(items_from_search)
    items_from_search.map { |child|
      "<li><a href='#{child[:link]}'>#{child[:title]}</a></li>"
    }.join
  end

  def accordion_items_from_search(subtopic_details, topic_type)
    accordion_items_from_search ||= begin
      max_query_count = 500
      browse_content_query_params = {
        count: max_query_count,
        fields: "title",
        order: "title",
      }
      if topic_type == :mainstream
        browse_content_query_params["filter_mainstream_browse_page_content_ids"] = subtopic_details["content_id"]
      elsif topic_type == :specialist
        browse_content_query_params["filter_specialist_sectors"] = subtopic_details["base_path"].sub("/topic/", "")
      else
        puts "Unknown topic type: #{topic_type}"
      end
      response = http_get("https://www.gov.uk/api/search.json?#{browse_content_query_params.to_query}")
      if response["total"] == max_query_count
        puts "WARNING: API returned item count limit (#{max_query_count}). There are probably more."
      end
      response["results"].map { |result| { title: result["title"].strip, link: result["_id"] } }
    end
  end

  def most_popular_content_results(subtopics, topic_type)
    most_popular_content ||= begin
      popular_content_query_params = {
        count: 3,
        fields: "title",
      }
      if topic_type == :mainstream
        popular_content_query_params["filter_mainstream_browse_pages"] =
          subtopics.map { |subtopic| subtopic["base_path"].sub("/browse/", "") }
      else
        popular_content_query_params["filter_specialist_sectors"] =
          subtopics.map { |subtopic| subtopic["base_path"].sub("/topic/", "") }
      end
      http_get("https://www.gov.uk/api/search.json?#{popular_content_query_params.to_query}")["results"]
    end
  end

  def most_popular_content(subtopics, topic_type)
    most_popular_content_results(subtopics, topic_type).map { |popular| { title: popular["title"], link: popular["_id"] } }
  end

  def latest_news_content(topic_type)
    topic_query(topic_type)["results"]
  end

  def topic_organisations(topic_type)
    # Comes from a response looking like: https://www.gov.uk/api/search.json?facet_organisations=20&count=0
    @topic_organisations ||= begin
      topic_query(topic_type)["facets"]["organisations"]["options"].map do |org_option|
        {
          title: org_option["value"]["title"],
          url: org_option["value"]["link"],
          crest: org_option["value"]["organisation_crest"],
          slug: org_option["value"]["slug"],
        }
      end
    end
  end

  def topic_query(topic_type)
    @topic_query ||= begin
      topic_path = "#{params[:topic_slug]}#{params[:subtopic_slug] ? '/' : ''}#{params[:subtopic_slug]}"
      topic_query_params = {
        count: 3,
        fields: %w[title description image_url public_timestamp content_purpose_supergroup content_purpose_subgroup],
        order: "-public_timestamp",
        facet_organisations: "20",
      }.merge(topic_filter(topic_path, topic_type))
      http_get("https://www.gov.uk/api/search.json?#{topic_query_params.to_query}")
    end
  end

  def taxon_filter(slug)
    taxon_id = Taxonomies.taxon_lookup(slug)
    if taxon_id.present?
      "filter_part_of_taxonomy_tree=#{taxon_id}"
    else
      ""
    end
  end

  def http_get(url)
    HTTParty.get(url, follow_redirects: true)
  end

  def breadcrumb_content(content_item, is_html_pub = false)
    return false if !content_item

    if is_html_pub
      breadcrumbs = []
      parent_content_item = http_get("https://www.gov.uk#{content_item.dig("links", "parent", 0, "api_path")}").parsed_response

      breadcrumb_content(parent_content_item)
    else
      if content_item.dig("links", "parent")
        breadcrumbs_by_parent(content_item.dig("links", "parent", 0))
      elsif content_item.dig("links", "topics")
        content_item.dig("links", "topics")
      elsif content_item.dig("links", "taxons")
        breadcrumbs_by_taxon(content_item.dig("links", "taxons", 0))
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

  def breadcrumbs_by_taxon(taxon)
    breadcrumbs = [taxon]
    potential_parent_taxon = taxon.dig("links", "parent_taxons", 0)

    if potential_parent_taxon
      (breadcrumbs << breadcrumbs_by_taxon(potential_parent_taxon)).flatten!
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
    parts.map do |part|
      contents_list_item = {
        text: part["title"],
      }

      is_active_page = part["slug"] == slug

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

  def format_collection_documents(documents)
    return [] unless documents.present?

    documents.map do |document|
      document["formatted_date"] = display_date(document["public_updated_at"])
      document["attribute"] = context_phrases[document["document_type"]]

      document
    end
  end

  def format_parts(parts, base_path, slug)
    stripped_slug = slug.gsub(base_path, "").gsub("/", "")
    filter = stripped_slug.empty? ? "overview": stripped_slug
    correct_part = parts.filter do |part|
      part["slug"] == filter
    end

    puts stripped_slug

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
end
