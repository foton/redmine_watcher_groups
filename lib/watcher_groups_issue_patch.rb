
module WatcherGroupsIssuePatch

  def self.included(base) # :nodoc:
    base.send(:include, InstanceMethods)
    base.class_eval do
      alias_method_chain :notified_watchers , :groups
      alias_method_chain :watched_by? , :groups
      alias_method_chain :watcher_users, :users
      alias_method_chain :set_watcher, :journal
    end
  end

  Issue.class_eval do
    include WatcherGroupsHelper

    scope :watched_by, lambda { |user|
      user = User.find(user) unless user.is_a?(User)
      g = user.groups
      joins(:watchers).where("#{Watcher.table_name}.user_id IN (#{user.id} #{g.empty? ? "" : ","} #{g.map(&:id).join(',')})")
    }

    def add_watcher_journal(action, watcher_name)
      if Setting['plugin_redmine_watcher_groups']['redmine_watcher_groups_log_watchers_setting'] == 'yes'
	journal = self.init_journal(User.current, l(action, :name => User.current.name, :target_name => watcher_name).html_safe)
	journal.save
      end
    end

    def watcher_groups
      if self.id
        groups = Watcher.where("watchable_type='#{self.class}' and watchable_id = #{self.id}")
        return [] if groups.empty?  
        Group.where(id: groups.map(&:user_id))
      end
    end

    def watcher_groups_ids
      self.watcher_groups.collect {|group| group.id}
    end

    def watcher_groups_ids=(group_ids)
      groups = group_ids.collect {|group_id| Group.find(group_id) if Group.find(group_id).is_a?(Group)  }
      user_ids = groups.map(&:users).flatten.compact.uniq.map(&:id)
      Watcher.delete_all "watchable_type = '#{self.class}' AND watchable_id = #{self.id} AND user_id IN (#{user_ids.join(',')})"
      groups.each do |group|
        self.add_watcher_group(group)
      end
    end

    # Returns an array of users that are proposed as watchers
    def addable_watcher_groups
      groups = self.project.principals.select{|p| p if p.type=='Group'}
      groups = groups.sort - self.watcher_groups
      if respond_to?(:visible?)
        groups.reject! {|group| !visible?(group)}
      end
      groups
    end

    # Adds group as a watcher
    def add_watcher_group(group)
      if Watcher.where("watchable_type='#{self.class}' and watchable_id = #{self.id} and user_id = '#{group.id}'").limit(1).blank?
        # insert directly into table to avoid user type checking
        Watcher.connection.execute("INSERT INTO #{Watcher.table_name} (user_id, watchable_id, watchable_type) VALUES (#{group.id}, #{self.id}, '#{self.class.name}')")
      end
    end

    # Removes user from the watchers list
    def remove_watcher_group(group)
      return nil unless group && group.is_a?(Group)
      Watcher.delete_all "watchable_type = '#{self.class}' AND watchable_id = #{self.id} AND user_id = #{group.id}"
    end

    # Adds/removes watcher
    def set_watcher_group(group, watching=true)
      watching ? add_watcher_group(group) : remove_watcher_group(group)
    end

    # Returns true if object is watched by +user+
    def watched_by_group?(group)
      !!(group && self.watcher_groups.detect {|gr| gr.id == group.id } unless self.watcher_groups.nil?)
    end

  end

  module InstanceMethods
    def notified_watchers_with_groups
      notified = []
      w = Watcher.where("watchable_type='#{self.class}' and watchable_id = #{self.id}")
      groups = Group.where(id: w.map(&:user_id))

      groups.each do |p|
          group_users = p.users.to_a
          group_users.reject! {|user| user.mail.blank? || user.mail_notification == 'none'}
          if respond_to?(:visible?)
            group_users.reject! {|user| !visible?(user)}
          end
          notified |= group_users
      end

      notified |= watcher_users.to_a
      notified.reject! {|user| user.mail.blank? || user.mail_notification == 'none'}
      if respond_to?(:visible?)
        notified.reject! {|user| !visible?(user)}
      end
      notified
    end

    def watched_by_with_groups?(user)
      watcher_groups.each do |group|
        return true if user.is_or_belongs_to?(group)
      end if self.id?
      watched_by_without_groups?(user)
    end

    def watcher_users_with_users
      users = watcher_users_without_users
      old_object = users
      watcher_groups.each do |g|
        users |= g.users
      end if self.id?
      users.define_singleton_method(:reset) do old_object.reset end if old_object.class != users.class
      users
    end

    def set_watcher_with_journal(user, watching=true)
      result = set_watcher_without_journal(user, watching)
      self.add_watcher_journal((watching ? :label_watcher_user_add : :label_watcher_user_remove), user.name)
      result
    end
  end
end

