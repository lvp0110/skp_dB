module Constrtodo
  module SkpDb

    PLUGIN_ID = 'ConstrtodoSkpDb'.freeze
    PLUGIN_NAME = 'ConstrTodo SKP'.freeze
    VERSION = '1.0.4'.freeze

    MODULE_PATH = File.dirname(__FILE__).freeze
    HTML_PATH = File.join(MODULE_PATH, 'html', 'index.html').freeze

    DEFAULT_API_ORIGIN = 'https://content.constrtodo.ru'.freeze
    DEFAULT_API_BASE = "#{DEFAULT_API_ORIGIN}/api".freeze
    CONTENT_TYPE_CODE = 'sketchup_model_for_material'.freeze
    CONTENT_TYPE_FALLBACKS = %w[
      sketchup_model_for_material
      sketchup_model_for_construction
    ].freeze

    PREF_API_BASE = 'api_base'.freeze
    PREF_EMAIL = 'email'.freeze
    PREF_COOKIES = 'cookies_json'.freeze
    PREF_CONTENT_TYPE = 'content_type'.freeze

    FILE_FIELD_TYPES = %w[file file_dwg file_pdf file_dxf file_skp].freeze
    NAME_FIELD_CODES = %w[name title header filename file_name model_name].freeze
    SKIP_UPLOAD_KEYS = %w[modelObjectId objectId groupId group_id].freeze
    FIELD_CODE_ALIASES = {
      'constr_code' => %w[construction_code construction constr ConstrCode constrCode]
    }.freeze

    STATUS_LABELS = {
      'draft' => 'Черновик',
      'pending' => 'На подписании',
      'approved' => 'Подписан',
      'rejected' => 'На доработку',
      'archived' => 'Архив',
      'archiving' => 'На архивацию'
    }.freeze

  end
end
