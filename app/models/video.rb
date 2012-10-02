class Video < ActiveRecord::Base
  belongs_to :checkin   # before/after video
  belongs_to :user      # profile video
  belongs_to :startup   # team video, pitch video

  attr_accessible :external_id, :user_id, :type, :vimeo_id, :image, :remote_image_url, :image_cache, :external_url, :youtube_url
  attr_accessor :youtube_url

  before_validation :extract_id_from_youtube_url
  before_save :check_if_needs_vimeo_upload, :unless => :new_record?
  before_save :flag_for_vimeo_upload, :if => :new_record?
  after_destroy :remove_from_vimeo_and_delete_local_file

  validates_presence_of :external_id
  validate :video_is_unique

  mount_uploader :image, BaseUploader # carrierwave file uploads

  @queue = :video

  def self.tmp_file_dir
    File.join(Rails.root, 'tmp', 'videos')
  end

  def tmp_file_name(extension = 'mp4')
    # generate random token if new record, or just return id
    beginning = self.new_record? ? "#{Time.now.to_i}#{Random.rand(20)}" : self.id
    "#{beginning}.#{extension}"
  end

  # Method to get embed code - no matter what kind of video
  def embed_code(width = 500, height = 315)
    if self.vimeod?
      '<iframe src="http://player.vimeo.com/video/' + self.vimeo_id.to_s + '?title=0&byline=0&portrait=0" width="' + width.to_s + '" height="' + height.to_s + '" frameborder="0" webkitAllowFullScreen mozallowfullscreen allowFullScreen></iframe>'
    else
      self.embed_code_html(width, height)
    end
  end

  # Mock - this method should return a string of html to play the video
  def embed_code_html(width = 500, height = 315)
    '[video embed]'
  end

  # Mock - to be implemented on any external video classes that inherit from the Video class
  def save_external_video_locally
    #self.save_file_locally
  end

  # Given a location of a file on a remote server it will save it locally to the tmp_file_dir
  # DOES NOT SAVE model
  # Will follow redirects
  def save_file_locally(remote_url_str, extension = nil)
    extension ||= remote_url_str.match(/\.\w+$/)[0].sub(/^\./, '')
    new_file_name = self.tmp_file_name(extension)
    local_path_to_file = File.join(Video.tmp_file_dir, new_file_name)

    # Make sure dir exists
    FileUtils.mkdir_p(Video.tmp_file_dir) unless File.exists?(Video.tmp_file_dir)

    # simple one-liner because using net/http just doesn't seem to work
    system("wget -O #{local_path_to_file} #{remote_url_str}")

    self.local_file_path = local_path_to_file if File.exists?(local_path_to_file)
    if self.local_file_path.blank?
      raise "Local file could not be saved" 
    else
      return true
    end
  end

  ## VIMEO SPECIFIC METHODS

  # Authenticated Vimeo client
  def self.vimeo_client
    Vimeo::Advanced::Video.new(Settings.apis.vimeo.client_id, Settings.apis.vimeo.client_secret, :token => Settings.apis.vimeo.access_token, :secret => Settings.apis.vimeo.access_token_secret)
  end

    # Method to take the external video and save it to our vimeo account
  # First it saves it locally, then it uploads to vimeo, finally saves object
  def transfer_to_vimeo!
    return true if self.vimeo_id.present?
    # Use individually implemented method to save file locally
    self.save_external_video_locally
    # Transfer to vimeo
    self.upload_to_vimeo(true)
    raise "Vimeo: video could not be uploaded from local file: #{path_to_local_file}" if self.vimeo_id.blank?
    self.save
    # Check to see if it has been encoded
    Resque.enqueue_in(5.minutes, Video, self.id, true)
  end

  # Transfers a local file (using local_file_path) to vimeo account
  # Adds vimeo_id to model on success - does not save
  # delete_on_success will delete the local file if it is successfully uploaded
  def upload_to_vimeo(delete_on_success = false)

    # Vimeo upload
    begin
      upload = Vimeo::Advanced::Upload.new(Settings.apis.vimeo.client_id, Settings.apis.vimeo.client_secret, :token => Settings.apis.vimeo.access_token, :secret => Settings.apis.vimeo.access_token_secret)
      uploaded_video = upload.upload(self.local_file_path)
      
      # Store vimeo id
      self.vimeo_id = uploaded_video['ticket']['video_id']
      
      self.set_desired_vimeo_permissions unless self.vimeo_id.blank?
    rescue => e
      raise e
    end

    # Remove local file
    if delete_on_success && self.vimeo_id.present?
      FileUtils.rm(self.local_file_path)
      self.local_file_path = nil
    end

    self.vimeo_id.blank? ? false : true
  end

  def set_desired_vimeo_permissions
    begin
      video = Vimeo::Advanced::Video.new(Settings.apis.vimeo.client_id, Settings.apis.vimeo.client_secret, :token => Settings.apis.vimeo.access_token, :secret => Settings.apis.vimeo.access_token_secret)
        
      # hide from vimeo.com
      video.set_privacy(self.vimeo_id, "disable", { :users => nil, :password => nil })
      
      # set embed preset to remove vimeo logo and add ours
      video_embed = Vimeo::Advanced::VideoEmbed.new(Settings.apis.vimeo.client_id, Settings.apis.vimeo.client_secret, :token => Settings.apis.vimeo.access_token, :secret => Settings.apis.vimeo.access_token_secret)
      video_embed.set_preset(self.vimeo_id, Settings.apis.vimeo.preset_id)

      # set video title
      video.set_title(self.vimeo_id, "#{self.id} - #{self.created_at.to_s}")
    rescue
      return false
    end
    true
  end

  def vimeo_details
    return nil if self.vimeo_id.blank?
    response = Video.vimeo_client.get_info(self.vimeo_id)
    return !response['video'].blank? ? response['video'].first : nil
  end

  def check_if_encoded_and_get_thumbnail_urls(queue_again = false)
    details = self.vimeo_details
    return false if details.blank?
    # Set as transcoded if it has completed
    self.vimeod = true if details['is_transcoding'].to_i == 0
    # Save image thumbnails
    if details['thumbnails'].present? && details['thumbnails']['thumbnail'].present? && details['thumbnails']['thumbnail'].last['_content'].match(/default\..*\.jpg/) == nil
      self.remote_image_url = details['thumbnails']['thumbnail'].last['_content']
      self.save
    else
      Resque.enqueue_in(5.minutes, Video, self.id, true)
      false
    end
  end

  # Downloads video and transfers to Vimeo
  def self.perform(video_id, check_if_encoded = false)
    v = Video.find(video_id)
    begin
      if v.vimeod? && check_if_encoded
        self.check_if_encoded_and_get_thumbnail_urls(true)
      else 
        # Transfer it to vimeo and queue encoding check
        v.transfer_to_vimeo! 
      end
    rescue
      # If it fails to download or video hasn't encoded yet, enqueue
      v.queue_transfer_to_vimeo
    end
  end

  def flag_for_vimeo_upload
    @transfer_to_vimeo = true
  end

  # only queues if flag_for_vimeo_upload is called
  def queue_transfer_to_vimeo(force_transfer = false)
    Resque.enqueue(Video, self.id) if @transfer_to_vimeo == true || force_transfer
  end

  # END VIMEO-SPECIFIC METHODS

  protected

  # Queue for upload to vimeo if the external id (linked video) has changed
  def check_if_needs_vimeo_upload
    self.flag_for_vimeo_upload if self.external_id.present? && self.external_id_changed?
  end

  # Pulls youtube id from youtube_url attribute
  def extract_id_from_youtube_url
    if self.youtube_url.present?
      url = self.youtube_url
      self.external_id = Youtube.id_from_url(url) if url.present?
      self.errors.add(:youtube_url, 'is not a valid Youtube URL') unless self.external_id.present?
    else
      true
    end
  end

  # Make sure there isn't another video already stored with same external id
  def video_is_unique
    if self.new_record? && self.external_id.present? && Video.where(:external_id => self.external_id, :type => self.class.to_s).count > 0
      self.errors.add(:external_id, 'is not unique')
      false
    else
      true
    end
  end

  def remove_from_vimeo_and_delete_local_file
    # Remove video from vimeo
    if self.vimeo_id.present?
      video = Vimeo::Advanced::Video.new(Settings.apis.vimeo.client_id, Settings.apis.vimeo.client_secret, :token => Settings.apis.vimeo.access_token, :secret => Settings.apis.vimeo.access_token_secret)
      video.delete(self.vimeo_id)
    end

    FileUtils.rm(self.local_file_path) if self.local_file_path.present? && File.exists?(self.local_file_path)
  end
end
