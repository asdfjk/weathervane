/*
Copyright 2017-2019 VMware, Inc.
SPDX-License-Identifier: BSD-2-Clause
*/
package com.vmware.weathervane.workloadDriver.common.statistics.statsIntervalSpec;

import java.util.List;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.client.RestTemplate;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonSubTypes.Type;
import com.fasterxml.jackson.annotation.JsonTypeInfo;
import com.fasterxml.jackson.annotation.JsonTypeInfo.As;
import com.vmware.weathervane.workloadDriver.common.representation.BasicResponse;
import com.vmware.weathervane.workloadDriver.common.representation.StatsIntervalCompleteMessage;

@JsonTypeInfo(use = com.fasterxml.jackson.annotation.JsonTypeInfo.Id.NAME, include = As.PROPERTY, property = "type")
@JsonSubTypes({ @Type(value = FixedStatsIntervalSpec.class, name = "fixed"), 
	@Type(value = PeriodicStatsIntervalSpec.class, name = "periodic")
})
public abstract class StatsIntervalSpec implements Runnable {
	private static final Logger logger = LoggerFactory.getLogger(StatsIntervalSpec.class);

	private String name;
	
	private Boolean printSummary;
	private Boolean printIntervals;
	private Boolean printCsv;

	@JsonIgnore
	private String curIntervalName;
	
	@JsonIgnore
	private List<String> hosts;

	@JsonIgnore
	private String runName = null;

	@JsonIgnore
	private String workloadName;	

	@JsonIgnore
	private static boolean finished = false;

	@JsonIgnore
	private ScheduledExecutorService statsExecutor;

	@JsonIgnore
	private RestTemplate restTemplate;

	@JsonIgnore
	private long curIntervalStartTime;

	@JsonIgnore
	private long lastIntervalEndTime;
	
	@JsonIgnore 
	private long intervalStartUsers = -1;
	
	@JsonIgnore
	private long intervalEndUsers = -1;

	@JsonIgnore
	protected abstract StatsInterval getNextInterval();

	public void initialize(String runName, String workloadName, List<String> hosts, RestTemplate resetTemplate,
			ScheduledExecutorService executorService) {
		this.runName = runName;
		this.workloadName = workloadName;
		this.hosts = hosts;
		this.restTemplate = resetTemplate;
		this.statsExecutor = executorService;				
	}

	public void start() {
		StatsInterval interval = this.getNextInterval();
		long wait = interval.getDuration();
		curIntervalName = interval.getName();
		
		if (!finished && (wait > 0)) {
			statsExecutor.schedule(this, wait, TimeUnit.SECONDS);
		}
		
		lastIntervalEndTime = curIntervalStartTime = System.currentTimeMillis();

	}

	public void stop() {
		finished = true;		
	}
	
	@Override
	public void run() {
		logger.debug("run");
		lastIntervalEndTime = System.currentTimeMillis();

		if (this.intervalEndUsers == -1) {
			this.intervalEndUsers = this.intervalStartUsers;
		}
		
		/*
		 * Send messages to workloadService on driver nodes indicating
		 * that stats interval is complete
		 */
		for (String hostname : hosts) {
			/*
			 * Send the statsIntervalComplete message for the workload to the host
			 */
			StatsIntervalCompleteMessage statsIntervalCompleteMessage = new StatsIntervalCompleteMessage();
			statsIntervalCompleteMessage.setCompletedSpecName(name);
			statsIntervalCompleteMessage.setCurIntervalName(curIntervalName);
			statsIntervalCompleteMessage.setCurIntervalStartTime(curIntervalStartTime);
			statsIntervalCompleteMessage.setLastIntervalEndTime(lastIntervalEndTime);
			statsIntervalCompleteMessage.setIntervalStartUsers(intervalStartUsers);
			statsIntervalCompleteMessage.setIntervalEndUsers(intervalEndUsers);
			
			HttpHeaders requestHeaders = new HttpHeaders();
			requestHeaders.setContentType(MediaType.APPLICATION_JSON);

			HttpEntity<StatsIntervalCompleteMessage> msgEntity 
				= new HttpEntity<StatsIntervalCompleteMessage>(statsIntervalCompleteMessage,
					requestHeaders);
			String url = "http://" + hostname + "/driver/run/" + runName + "/workload/" + workloadName + "/statsIntervalComplete";
			logger.debug("run sending statsIntervalComplete message for run " + runName + ", workload " + workloadName 
					+ " to host " + hostname + ", url = " + url);
			ResponseEntity<BasicResponse> responseEntity = restTemplate.exchange(url, HttpMethod.POST, msgEntity,
					BasicResponse.class);

			BasicResponse response = responseEntity.getBody();
			if (responseEntity.getStatusCode() != HttpStatus.OK) {
				logger.error("Error posting statsIntervalComplete message to " + url);
			}
		}
		intervalStartUsers = intervalEndUsers;		
		curIntervalStartTime = lastIntervalEndTime;

		StatsInterval interval = this.getNextInterval();
		long wait = interval.getDuration();
		curIntervalName = interval.getName();
		
		if ((!finished) && (wait > 0)) {
			logger.debug("run. Scheduling next interval for " + wait + " seconds.");
			statsExecutor.schedule(this, wait, TimeUnit.SECONDS);
		}

	}
	
	public String getName() {
		return name;
	}

	public void setName(String name) {
		this.name = name;
	}

	public Boolean getPrintSummary() {
		return printSummary;
	}

	public void setPrintSummary(Boolean printSummary) {
		this.printSummary = printSummary;
	}
	
	public Boolean getPrintIntervals() {
		return this.printIntervals;
	}

	public void setPrintIntervals(Boolean printIntervals) {
		this.printIntervals = printIntervals;
	}

	public Boolean getPrintCsv() {
		return this.printCsv;
	}

	public void setPrintCsv(Boolean printCsv) {
		this.printCsv = printCsv;
	}

	public String getCurIntervalName() {
		return curIntervalName;
	}

	public void setCurIntervalName(String curIntervalName) {
		this.curIntervalName = curIntervalName;
	}

	public void setActiveUsers(long users) {
		logger.debug("setActiveUsers to " + users + " users");
		if (this.intervalStartUsers == -1) {
			logger.debug("setActiveUsers setting intervalStartUsers to " + users + " users");
			this.intervalStartUsers = users;
		} else {
			logger.debug("setActiveUsers setting intervalEndUsers to " + users + " users");
			this.intervalEndUsers = users;
		}
	}

}
