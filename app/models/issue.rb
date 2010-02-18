# BetterMeans - Work 2.0
# Copyright (C) 2009  Shereef Bishay
#

class Issue < ActiveRecord::Base
  belongs_to :project
  belongs_to :tracker
  belongs_to :status, :class_name => 'IssueStatus', :foreign_key => 'status_id'
  belongs_to :author, :class_name => 'User', :foreign_key => 'author_id'
  belongs_to :assigned_to, :class_name => 'User', :foreign_key => 'assigned_to_id'
  belongs_to :fixed_version, :class_name => 'Version', :foreign_key => 'fixed_version_id'
  belongs_to :priority, :class_name => 'IssuePriority', :foreign_key => 'priority_id'
  belongs_to :retro
  # belongs_to :category, :class_name => 'IssueCategory', :foreign_key => 'category_id'
    
  has_many :journals, :as => :journalized, :dependent => :destroy
  has_many :time_entries, :dependent => :delete_all
  has_and_belongs_to_many :changesets, :order => "#{Changeset.table_name}.committed_on ASC, #{Changeset.table_name}.id ASC"
  
  has_many :relations_from, :class_name => 'IssueRelation', :foreign_key => 'issue_from_id', :dependent => :delete_all
  has_many :relations_to, :class_name => 'IssueRelation', :foreign_key => 'issue_to_id', :dependent => :delete_all
  
  has_many :commit_requests, :dependent => :delete_all
  has_many :issue_votes, :dependent => :delete_all
  has_many :todos, :dependent => :delete_all
  
  acts_as_voteable #for vote_fu plugin
  acts_as_attachable :after_remove => :attachment_removed
  acts_as_customizable
  acts_as_watchable
  acts_as_searchable :columns => ['subject', "#{table_name}.description", "#{Journal.table_name}.notes"],
                     :include => [:project, :journals],
                     # sort by id so that limited eager loading doesn't break with postgresql
                     :order_column => "#{table_name}.id"
  acts_as_event :title => Proc.new {|o| "#{o.tracker.name} ##{o.id} (#{o.status}): #{o.subject}"},
                :url => Proc.new {|o| {:controller => 'issues', :action => 'show', :id => o.id}},
                :type => Proc.new {|o| 'issue' + (o.closed? ? ' closed' : '') }
  
  acts_as_activity_provider :find_options => {:include => [:project, :author, :tracker]},
                            :author_key => :author_id

  DONE_RATIO_OPTIONS = %w(issue_field issue_status)
  
  validates_presence_of :subject, :project, :tracker, :author, :status #,:priority,
  validates_length_of :subject, :maximum => 255
  validates_inclusion_of :done_ratio, :in => 0..100
  validates_numericality_of :estimated_hours, :allow_nil => true

  named_scope :visible, lambda {|*args| { :include => :project,
                                          :conditions => Project.allowed_to_condition(args.first || User.current, :view_issues) } }
  
  named_scope :open, :conditions => ["#{IssueStatus.table_name}.is_closed = ?", false], :include => :status

  before_save :update_done_ratio_from_issue_status
  after_save :after_save
  
  # Returns true if usr or current user is allowed to view the issue
  def visible?(usr=nil)
    (usr || User.current).allowed_to?(:view_issues, self.project)
  end
  
  # Returns true if there are enough agreements in relation to the estimated points of the request
  def ready_for_open?
    return false if points.nil? || agree_total < 1
    return true if agree_total >= points
    return true if agree_total > (project.root.core_members.count / 2)
    return false
  end

  def ready_for_accepted?
    return false if points.nil? || accept_total < 1
    return true if accept_total >= points
    return true if accept_total > (project.root.core_members.count / 2)
    return false
  end
  
  def updated_status
    return IssueStatus.newstatus if agree_total < 1
    return IssueStatus.open if ready_for_open?
    return IssueStatus.estimate if agree_total > 0 
    return IssueStatus.newstatus #default
  end
  
  def after_initialize
    if new_record?
      # set default values for new records only
      self.status ||= IssueStatus.default
      # self.priority ||= IssuePriority.default
    end
  end
  
  # Returns true if one or more people joined this issue
  def has_team?
    if issue_votes.sum(:points, :conditions => {:vote_type => IssueVote::JOIN_VOTE_TYPE}) > 1 #It's always going to be at least one, since the onwer is the first person on there
      return true
    else 
      return false
    end
  end

  
  
  # Overrides Redmine::Acts::Customizable::InstanceMethods#available_custom_fields
  def available_custom_fields
    (project && tracker) ? project.all_issue_custom_fields.select {|c| tracker.custom_fields.include? c } : []
  end
  
  def copy_from(arg)
    issue = arg.is_a?(Issue) ? arg : Issue.find(arg)
    self.attributes = issue.attributes.dup.except("id", "created_on", "updated_on")
    self.custom_values = issue.custom_values.collect {|v| v.clone}
    self.status = issue.status
    self
  end
  
  # Moves/copies an issue to a new project and tracker
  # Returns the moved/copied issue on success, false on failure
  def move_to(new_project, new_tracker = nil, options = {})
    options ||= {}
    issue = options[:copy] ? self.clone : self
    transaction do
      if new_project && issue.project_id != new_project.id
        # delete issue relations
        unless Setting.cross_project_issue_relations?
          issue.relations_from.clear
          issue.relations_to.clear
        end
        # issue is moved to another project
        # reassign to the category with same name if any
        # new_category = issue.category.nil? ? nil : new_project.issue_categories.find_by_name(issue.category.name)
        # issue.category = new_category
        # Keep the fixed_version if it's still valid in the new_project
        unless new_project.shared_versions.include?(issue.fixed_version)
          issue.fixed_version = nil
        end
        issue.project = new_project
      end
      if new_tracker
        issue.tracker = new_tracker
      end
      if options[:copy]
        issue.custom_field_values = self.custom_field_values.inject({}) {|h,v| h[v.custom_field_id] = v.value; h}
        issue.status = if options[:attributes] && options[:attributes][:status_id]
                         IssueStatus.find_by_id(options[:attributes][:status_id])
                       else
                         self.status
                       end
      end
      # Allow bulk setting of attributes on the issue
      if options[:attributes]
        issue.attributes = options[:attributes]
      end
      if issue.save
        unless options[:copy]
          # Manually update project_id on related time entries
          TimeEntry.update_all("project_id = #{new_project.id}", {:issue_id => id})
        end
      else
        Issue.connection.rollback_db_transaction
        return false
      end
    end
    return issue
  end
  
  def priority_id=(pid)
    self.priority = nil
    write_attribute(:priority_id, pid)
  end

  def tracker_id=(tid)
    self.tracker = nil
    write_attribute(:tracker_id, tid)
    result = write_attribute(:tracker_id, tid)
    @custom_field_values = nil
    result
  end
  
  # Overrides attributes= so that tracker_id gets assigned first
  def attributes_with_tracker_first=(new_attributes, *args)
    return if new_attributes.nil?
    new_tracker_id = new_attributes['tracker_id'] || new_attributes[:tracker_id]
    if new_tracker_id
      self.tracker_id = new_tracker_id
    end
    self.attributes_without_tracker_first = new_attributes, *args
  end
  alias_method_chain :attributes=, :tracker_first
  
  def estimated_hours=(h)
    write_attribute :estimated_hours, (h.is_a?(String) ? h.to_hours : h)
  end
  
  def done_ratio
    if Issue.use_status_for_done_ratio? && status && status.default_done_ratio?
      status.default_done_ratio
    else
      read_attribute(:done_ratio)
    end
  end

  def self.use_status_for_done_ratio?
    Setting.issue_done_ratio == 'issue_status'
  end

  def self.use_field_for_done_ratio?
    Setting.issue_done_ratio == 'issue_field'
  end
  
  def validate
    if self.due_date.nil? && @attributes['due_date'] && !@attributes['due_date'].empty?
      errors.add :due_date, :not_a_date
    end
    
    if self.due_date and self.start_date and self.due_date < self.start_date
      errors.add :due_date, :greater_than_start_date
    end
    
    if start_date && soonest_start && start_date < soonest_start
      errors.add :start_date, :invalid
    end
    
    if fixed_version
      if !assignable_versions.include?(fixed_version)
        errors.add :fixed_version_id, :inclusion
      elsif reopened? && fixed_version.closed?
        errors.add_to_base I18n.t(:error_can_not_reopen_issue_on_closed_version)
      end
    end
    
    # Checks that the issue can not be added/moved to a disabled tracker
    # if project && (tracker_id_changed? || project_id_changed?)
    #   unless project.trackers.include?(tracker)
    #     errors.add :tracker_id, :inclusion
    #   end
    # end
    
  end

# Commenting this since on bettermeans all projects will have same trackers  
  # def validate_on_create
  #   errors.add :tracker_id, :invalid unless project.trackers.include?(tracker)
  # end
  
  def before_create
    # default assignment based on category
    # if assigned_to.nil? && category && category.assigned_to
    #   self.assigned_to = category.assigned_to
    # end
  end
  
  # Set the done_ratio using the status if that setting is set.  This will keep the done_ratios
  # even if the user turns off the setting later
  def update_done_ratio_from_issue_status
    if Issue.use_status_for_done_ratio? && status && status.default_done_ratio?
      self.done_ratio = status.default_done_ratio
    end
  end
  
  def after_save
    # Reload is needed in order to get the right status
    reload
    
    # Update start/due dates of following issues
    relations_from.each(&:set_issue_to_dates)
    
    # Close duplicates if the issue was closed
    if @issue_before_change && !@issue_before_change.closed? && self.closed?
      duplicates.each do |duplicate|
        # Reload is need in case the duplicate was updated by a previous duplicate
        duplicate.reload
        # Don't re-close it if it's already closed
        next if duplicate.closed?
        # Same user and notes
        duplicate.init_journal(@current_journal.user, @current_journal.notes)
        duplicate.update_attribute :status, self.status
      end
    end    
  end
  
  def init_journal(user, notes = "")
    @current_journal ||= Journal.new(:journalized => self, :user => user, :notes => notes)
    @issue_before_change = self.clone
    @issue_before_change.status = self.status
    @custom_values_before_change = {}
    self.custom_values.each {|c| @custom_values_before_change.store c.custom_field_id, c.value }
    # Make sure updated_on is updated when adding a note.
    updated_on_will_change!
    @current_journal
  end
  
  # Return true if the issue is closed, otherwise false
  def closed?
    self.status.is_closed?
  end
  
  # Return true if the issue is being reopened
  def reopened?
    if !new_record? && status_id_changed?
      status_was = IssueStatus.find_by_id(status_id_was)
      status_new = IssueStatus.find_by_id(status_id)
      if status_was && status_new && status_was.is_closed? && !status_new.is_closed?
        return true
      end
    end
    false
  end
  
  # Returns true if the issue is overdue
  def overdue?
    !due_date.nil? && (due_date < Date.today) && !status.is_closed?
  end
  
  # Users the issue can be assigned to
  def assignable_users
    project.assignable_users
  end
  
  # Versions that the issue can be assigned to
  def assignable_versions
    @assignable_versions ||= (project.shared_versions.open + [Version.find_by_id(fixed_version_id_was)]).compact.uniq.sort
  end
  
  # Returns true if this issue is blocked by another issue that is still open
  def blocked?
    !relations_to.detect {|ir| ir.relation_type == 'blocks' && !ir.issue_from.closed?}.nil?
  end
  
  # Returns an array of status that user is able to apply
  def new_statuses_allowed_to(user)
    statuses = status.find_new_statuses_allowed_to(user.roles_for_project(project), tracker)
    statuses << status unless statuses.empty?
    statuses = statuses.uniq.sort
    blocked? ? statuses.reject {|s| s.is_closed?} : statuses
  end
  
  # Returns the mail adresses of users that should be notified
  def recipients
    notified = project.notified_users
    # Author and assignee are always notified unless they have been locked
    notified << author if author && author.active?
    notified << assigned_to if assigned_to && assigned_to.active?
    notified.uniq!
    # Remove users that can not view the issue
    notified.reject! {|user| !visible?(user)}
    notified.collect(&:mail)
  end
  
  # Returns the total number of hours spent on this issue.
  #
  # Example:
  #   spent_hours => 0
  #   spent_hours => 50
  def spent_hours
    @spent_hours ||= time_entries.sum(:hours) || 0
  end
  
  def relations
    (relations_from + relations_to).sort
  end
  
  def all_dependent_issues
    dependencies = []
    relations_from.each do |relation|
      dependencies << relation.issue_to
      dependencies += relation.issue_to.all_dependent_issues
    end
    dependencies
  end
  
  # Returns an array of issues that duplicate this one
  def duplicates
    relations_to.select {|r| r.relation_type == IssueRelation::TYPE_DUPLICATES}.collect {|r| r.issue_from}
  end
  
  # Returns the due date or the target due date if any
  # Used on gantt chart
  def due_before
    due_date || (fixed_version ? fixed_version.effective_date : nil)
  end
  
  # Returns the time scheduled for this issue.
  # 
  # Example:
  #   Start Date: 2/26/09, End Date: 3/04/09
  #   duration => 6
  def duration
    (start_date && due_date) ? due_date - start_date : 0
  end
  
  def soonest_start
    @soonest_start ||= relations_to.collect{|relation| relation.successor_soonest_start}.compact.min
  end
  
  def to_s
    "#{tracker} ##{id}: #{subject}"
  end
  
  # Returns a string of css classes that apply to the issue
  def css_classes
    s = "issue status-#{status.position} priority-#{priority.nil? ? 2 : priority.position}" #BUGBUG 2 is hardcoded
    s << ' closed' if closed?
    s << ' overdue' if overdue?
    s << ' created-by-me' if User.current.logged? && author_id == User.current.id
    s << ' assigned-to-me' if User.current.logged? && assigned_to_id == User.current.id
    s
  end

  # Unassigns issues from +version+ if it's no longer shared with issue's project
  def self.update_versions_from_sharing_change(version)
    # Update issues assigned to the version
    update_versions(["#{Issue.table_name}.fixed_version_id = ?", version.id])
  end
  
  
  #returns true if this user is allowed to take (and/or offer) ownership for this particular issue
  def push_allowed?(user)
    return false if user.nil?
    return true if self.assigned_to == user #Any user who owns an issue can offer for people to take it, or can accept offers
    
    #True if user has push commitment, AND expected date has passed or doesn't exist AND it's assigned to nobody or assigned to same user
    user.allowed_to?(:push_commitment, self.project) && (self.expected_date.nil? || self.expected_date < Time.new.to_date) && (self.assigned_to.nil? || self.assigned_to == user)
  end
  
  # Unassigns issues from versions that are no longer shared
  # after +project+ was moved
  def self.update_versions_from_hierarchy_change(project)
    moved_project_ids = project.self_and_descendants.reload.collect(&:id)
    # Update issues of the moved projects and issues assigned to a version of a moved project
    Issue.update_versions(["#{Version.table_name}.project_id IN (?) OR #{Issue.table_name}.project_id IN (?)", moved_project_ids, moved_project_ids])
  end
  
  def update_estimate_total
    self.points =   IssueVote.average(:points, :conditions => {:issue_id => self.id, :vote_type => IssueVote::ESTIMATE_VOTE_TYPE})
  end

  def update_pri_total
    self.pri = IssueVote.sum(:points, :conditions => {:issue_id => self.id, :vote_type => IssueVote::PRI_VOTE_TYPE})
  end

  def update_agree_total
    self.agree =   IssueVote.count(:conditions => {:issue_id => self.id, :vote_type => IssueVote::AGREE_VOTE_TYPE, :points => 1})
    self.disagree =   IssueVote.count(:conditions => {:issue_id => self.id, :vote_type => IssueVote::AGREE_VOTE_TYPE, :points => -1})
    self.agree_total = self.agree - self.disagree
  end

  def update_accept_total
    self.accept =   IssueVote.count(:conditions => {:issue_id => self.id, :vote_type => IssueVote::ACCEPT_VOTE_TYPE, :points => 1})
    self.reject =   IssueVote.count(:conditions => {:issue_id => self.id, :vote_type => IssueVote::ACCEPT_VOTE_TYPE, :points => -1})
    self.accept_total = self.accept - self.reject
  end
  
  #returns json object for consumption from dashboard
  def to_dashboard
    self.to_json(:include => {:journals => {:include => :user}, :issue_votes => {:include => :user}, :status => {:only => :name}, :todos => {:only => [:id, :subject, :completed_on]}, :tracker => {:only => [:name,:id]}, :author => {:only => [:firstname, :lastname, :login]}, :assigned_to => {:only => [:firstname, :lastname, :login]}})
  end

  private
  
  # Update issues so their versions are not pointing to a
  # fixed_version that is not shared with the issue's project
  def self.update_versions(conditions=nil)
    # Only need to update issues with a fixed_version from
    # a different project and that is not systemwide shared
    Issue.all(:conditions => merge_conditions("#{Issue.table_name}.fixed_version_id IS NOT NULL" +
                                                " AND #{Issue.table_name}.project_id <> #{Version.table_name}.project_id" +
                                                " AND #{Version.table_name}.sharing <> 'system'",
                                                conditions),
              :include => [:project, :fixed_version]
              ).each do |issue|
      next if issue.project.nil? || issue.fixed_version.nil?
      unless issue.project.shared_versions.include?(issue.fixed_version)
        issue.init_journal(User.current)
        issue.fixed_version = nil
        issue.save
      end
    end
  end
  
  # Callback on attachment deletion
  def attachment_removed(obj)
    journal = init_journal(User.current)
    journal.details << JournalDetail.new(:property => 'attachment',
                                         :prop_key => obj.id,
                                         :old_value => obj.filename)
    journal.save
  end
  
  def after_save
    update_last_item_stamp
    create_journal
  end
  
  def update_last_item_stamp
    project.last_item_updated_on = DateTime.now
    project.save!
  end
  
  # Saves the changes in a Journal
  # Called after_save
  def create_journal
    if @current_journal
      # attributes changes
      (Issue.column_names - %w(id description lock_version created_on updated_on)).each {|c|
        @current_journal.details << JournalDetail.new(:property => 'attr',
                                                      :prop_key => c,
                                                      :old_value => @issue_before_change.send(c),
                                                      :value => send(c)) unless send(c)==@issue_before_change.send(c)
      }
      # custom fields changes
      custom_values.each {|c|
        next if (@custom_values_before_change[c.custom_field_id]==c.value ||
                  (@custom_values_before_change[c.custom_field_id].blank? && c.value.blank?))
        @current_journal.details << JournalDetail.new(:property => 'cf', 
                                                      :prop_key => c.custom_field_id,
                                                      :old_value => @custom_values_before_change[c.custom_field_id],
                                                      :value => c.value)
      }      
      @current_journal.save
    end
  end
  
  
  
  
end







# == Schema Information
#
# Table name: issues
#
#  id               :integer         not null, primary key
#  tracker_id       :integer         default(0), not null
#  project_id       :integer         default(0), not null
#  subject          :string(255)     default(""), not null
#  description      :text
#  due_date         :date
#  category_id      :integer
#  status_id        :integer         default(0), not null
#  assigned_to_id   :integer
#  priority_id      :integer         default(0), not null
#  fixed_version_id :integer
#  author_id        :integer         default(0), not null
#  lock_version     :integer         default(0), not null
#  created_on       :datetime
#  updated_on       :datetime
#  start_date       :date
#  done_ratio       :integer         default(0), not null
#  estimated_hours  :float
#  expected_date    :date
#  points           :float
#  pri              :integer         default(0)
#  accept           :integer         default(0)
#  reject           :integer         default(0)
#  accept_total     :integer         default(0)
#  agree            :integer         default(0)
#  disagree         :integer         default(0)
#  agree_total      :integer         default(0)
#  retro_id         :integer
#

